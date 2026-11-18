-- nfqws2 custom desync functions
-- Consolidates active desync strategies, TLS/HTTP modifiers, and Discord voice optimizations

-- AGGRESSIVE HTTP BYPASS for stubborn DPI (like porno365)
-- Combines multiple techniques: fake flood + disorder + host splitting
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : fakes=N - number of fake packets to send (default 5)
-- arg : ttl_start=N - starting TTL for fakes (default 1)
-- arg : ttl_step=N - TTL increment for each fake (default 1)
-- arg : split_host - additionally split inside hostname
-- arg : disorder - send parts in reverse order
function http_aggressive(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			-- Parse HTTP request
			local hdis = http_dissect_req(data)
			local host_idx = hdis and array_field_search(hdis.headers, "header_low", "host")
			if not host_idx then
				DLOG("http_aggressive: cannot parse HTTP request or no Host header")
				return
			end

			local host_pos = hdis.headers[host_idx]
			-- pos_end points to end of line (before \r\n), pos_value_start to start of value
			local host_value = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)

			DLOG("http_aggressive: detected Host: "..host_value)

			-- Options for fake packets (will die before reaching server)
			local opts_fake = {
				rawsend = rawsend_opts(desync),
				reconstruct = reconstruct_opts(desync),
				ipfrag = {},
				ipid = desync.arg,
				fooling = desync.arg
			}

			-- Options for real packets (no fooling except tcp_ts_up)
			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				ipid = desync.arg,
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}

			local num_fakes = tonumber(desync.arg.fakes) or 5
			local ttl_start = tonumber(desync.arg.ttl_start) or 1
			local ttl_step = tonumber(desync.arg.ttl_step) or 1

			-- Generate fake HTTP request with different host
			local fake_host = "www.google.com"
			local fake_data = string.sub(data, 1, host_pos.pos_value_start-1) ..
							  fake_host ..
							  string.sub(data, host_pos.pos_end+1)

			-- STEP 1: Send multiple fake packets with low TTL (will die before DPI or server)
			for i=1,num_fakes do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data

				-- Set low TTL so packet dies before reaching server
				local ttl = ttl_start + (i-1) * ttl_step
				if fake_dis.ip then
					fake_dis.ip.ip_ttl = ttl
				end
				if fake_dis.ip6 then
					fake_dis.ip6.ip6_hlim = ttl
				end

				-- Add badseq to confuse DPI further
				if fake_dis.tcp then
					fake_dis.tcp.th_ack = fake_dis.tcp.th_ack - 66000
				end

				if b_debug then DLOG("http_aggressive: sending fake #"..i.." TTL="..ttl) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			-- STEP 2: Split real request into parts
			-- Split points: before "Host:", middle of host, after host value
			local split_positions = {}

			-- Always split before "Host:" header
			table.insert(split_positions, host_pos.pos_start)

			-- Optionally split in the middle of hostname
			if desync.arg.split_host then
				local host_mid = host_pos.pos_value_start + math.floor(#host_value / 2)
				if host_mid > host_pos.pos_value_start and host_mid < host_pos.pos_end then
					table.insert(split_positions, host_mid)
				end
			end

			-- Split after Host header value
			table.insert(split_positions, host_pos.pos_end + 1)

			-- Sort positions
			table.sort(split_positions)

			-- Create parts
			local parts = {}
			local prev_pos = 1
			for i, pos in ipairs(split_positions) do
				if pos > prev_pos and pos <= #data then
					table.insert(parts, {
						data = string.sub(data, prev_pos, pos-1),
						offset = prev_pos - 1
					})
					prev_pos = pos
				end
			end
			-- Add remaining part
			if prev_pos <= #data then
				table.insert(parts, {
					data = string.sub(data, prev_pos),
					offset = prev_pos - 1
				})
			end

			if b_debug then
				DLOG("http_aggressive: split into "..#parts.." parts")
				for i, p in ipairs(parts) do
					DLOG("http_aggressive: part "..i.." offset="..p.offset.." len="..#p.data)
				end
			end

			-- STEP 3: Send parts (optionally in disorder)
			if desync.arg.disorder and #parts > 1 then
				-- Send in reverse order (disorder)
				for i=#parts,1,-1 do
					if b_debug then DLOG("http_aggressive: sending part "..i.." (disorder)") end
					if not rawsend_payload_segmented(desync, parts[i].data, parts[i].offset, opts_orig) then
						return VERDICT_PASS
					end
				end
			else
				-- Send in normal order
				for i=1,#parts do
					if b_debug then DLOG("http_aggressive: sending part "..i) end
					if not rawsend_payload_segmented(desync, parts[i].data, parts[i].offset, opts_orig) then
						return VERDICT_PASS
					end
				end
			end

			-- STEP 4: Send more fakes after real data (sandwich technique)
			for i=1,math.floor(num_fakes/2) do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				if fake_dis.ip then
					fake_dis.ip.ip_ttl = ttl_start
				end
				if fake_dis.ip6 then
					fake_dis.ip6.ip6_hlim = ttl_start
				end
				if fake_dis.tcp then
					fake_dis.tcp.th_ack = fake_dis.tcp.th_ack - 66000
				end
				if b_debug then DLOG("http_aggressive: sending trailing fake #"..i) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("http_aggressive: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- HTTP with multiple disorder splits at critical positions
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- Splits at: method, path, host header name, host value (multiple cuts)
function http_multidisorder(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			-- Generate split positions for HTTP
			local positions = {}

			-- Split at position 1 (after first byte)
			table.insert(positions, 2)

			-- Find key positions in HTTP request
			local method_end = string.find(data, " ")
			if method_end then
				table.insert(positions, method_end)
				table.insert(positions, method_end + 1)
			end

			-- Find Host: header
			local host_start = string.find(data, "\r\nHost: ", 1, true)
			if host_start then
				table.insert(positions, host_start + 2) -- before "Host:"
				table.insert(positions, host_start + 8) -- after "Host: "

				-- Find end of host value
				local host_end = string.find(data, "\r\n", host_start + 8, true)
				if host_end then
					-- Split in middle of host value
					local mid = host_start + 8 + math.floor((host_end - host_start - 8) / 2)
					table.insert(positions, mid)
					table.insert(positions, host_end)
				end
			end

			-- Remove duplicates and sort
			local unique_pos = {}
			local seen = {}
			for _, p in ipairs(positions) do
				if p > 1 and p <= #data and not seen[p] then
					table.insert(unique_pos, p)
					seen[p] = true
				end
			end
			table.sort(unique_pos)

			if b_debug then DLOG("http_multidisorder: split positions: "..table.concat(unique_pos, ",")) end

			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				ipid = desync.arg,
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}

			-- Create and send parts in reverse order
			local parts = {}
			local prev = 1
			for _, pos in ipairs(unique_pos) do
				if pos > prev then
					table.insert(parts, {string.sub(data, prev, pos-1), prev-1})
					prev = pos
				end
			end
			if prev <= #data then
				table.insert(parts, {string.sub(data, prev), prev-1})
			end

			-- Send in reverse order (disorder)
			for i=#parts,1,-1 do
				if b_debug then DLOG("http_multidisorder: sending part "..i.." offset="..parts[i][2].." len="..#parts[i][1]) end
				if not rawsend_payload_segmented(desync, parts[i][1], parts[i][2], opts_orig) then
					return VERDICT_PASS
				end
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("http_multidisorder: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- AGGRESSIVE TLS BYPASS for stubborn DPI (like browserleaks.com)
-- Combines multiple techniques: fake flood + SNI split + disorder + seqovl
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : fakes=N - number of fake packets to send (default 6)
-- arg : ttl_start=N - starting TTL for fakes (default 1)
-- arg : ttl_step=N - TTL increment for each fake (default 1)
-- arg : seqovl=N - sequence overlap size (default 0)
-- arg : seqovl_pattern=<blob> - pattern for seqovl
-- arg : fake_sni=<str> - SNI for fake packets (default www.google.com)
-- arg : split_sni - split inside SNI
-- arg : badseq - use badseq fooling on fakes
-- arg : md5sig - use md5sig fooling on fakes
function tls_aggressive(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			DLOG("tls_aggressive: processing TLS Client Hello len="..#data)

			-- Options for fake packets (will die before reaching server)
			local opts_fake = {
				rawsend = rawsend_opts(desync),
				reconstruct = reconstruct_opts(desync),
				ipfrag = {},
				ipid = desync.arg,
				fooling = desync.arg
			}

			-- Options for real packets (no fooling except tcp_ts_up)
			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				ipid = desync.arg,
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}

			local num_fakes = tonumber(desync.arg.fakes) or 6
			local ttl_start = tonumber(desync.arg.ttl_start) or 1
			local ttl_step = tonumber(desync.arg.ttl_step) or 1
			local fake_sni = desync.arg.fake_sni or "www.google.com"

			-- Generate fake TLS Client Hello with different SNI using tls_mod
			local fake_blob = desync.arg.blob and blob(desync, desync.arg.blob) or blob(desync, "fake_default_tls")
			local fake_data = fake_blob
			if desync.arg.tls_mod then
				fake_data = tls_mod(fake_data, desync.arg.tls_mod, desync.reasm_data)
			else
				-- Default: randomize and set fake SNI
				fake_data = tls_mod(fake_data, "rnd,dupsid,sni="..fake_sni, desync.reasm_data)
			end

			-- STEP 1: Send multiple fake packets with low TTL
			for i=1,num_fakes do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data

				local ttl = ttl_start + (i-1) * ttl_step
				if fake_dis.ip then
					fake_dis.ip.ip_ttl = ttl
				end
				if fake_dis.ip6 then
					fake_dis.ip6.ip6_hlim = ttl
				end

				-- Apply fooling based on args
				if fake_dis.tcp then
					if desync.arg.badseq then
						fake_dis.tcp.th_ack = fake_dis.tcp.th_ack - 66000
					end
				end

				if b_debug then DLOG("tls_aggressive: sending fake #"..i.." TTL="..ttl.." len="..#fake_data) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			-- STEP 2: Determine split positions for TLS Client Hello
			-- Key positions: start, after record header, SNI positions
			local split_positions = {}

			-- Always split at position 1 (minimal split)
			table.insert(split_positions, 2)

			-- Try to find SNI in TLS Client Hello using resolve_multi_pos
			local sni_positions = resolve_multi_pos(data, "tls_client_hello", "host,midsld,endhost")
			if sni_positions and #sni_positions >= 2 then
				for _, pos in ipairs(sni_positions) do
					if pos > 1 and pos <= #data then
						table.insert(split_positions, pos)
					end
				end
				if b_debug then DLOG("tls_aggressive: found SNI positions: "..table.concat(sni_positions, ",")) end
			else
				-- Fallback: split at fixed positions
				local tls_header_end = 6 -- After TLS record header
				if tls_header_end < #data then
					table.insert(split_positions, tls_header_end)
				end
				-- Split at ~1/3 and ~2/3 of data
				local third = math.floor(#data / 3)
				if third > 5 then
					table.insert(split_positions, third)
					table.insert(split_positions, third * 2)
				end
			end

			-- Also try sniext positions
			local sniext_positions = resolve_multi_pos(data, "tls_client_hello", "sniext,sniext+1,sniext+2")
			if sniext_positions then
				for _, pos in ipairs(sniext_positions) do
					if pos > 1 and pos <= #data then
						table.insert(split_positions, pos)
					end
				end
			end

			-- Remove duplicates and sort
			local unique_pos = {}
			local seen = {}
			for _, p in ipairs(split_positions) do
				if p > 1 and p <= #data and not seen[p] then
					table.insert(unique_pos, p)
					seen[p] = true
				end
			end
			table.sort(unique_pos)

			if b_debug then DLOG("tls_aggressive: split positions: "..table.concat(unique_pos, ",")) end

			-- Create parts
			local parts = {}
			local prev = 1
			for _, pos in ipairs(unique_pos) do
				if pos > prev then
					table.insert(parts, {string.sub(data, prev, pos-1), prev-1})
					prev = pos
				end
			end
			if prev <= #data then
				table.insert(parts, {string.sub(data, prev), prev-1})
			end

			if b_debug then DLOG("tls_aggressive: created "..#parts.." parts") end

			-- STEP 3: Send parts in reverse order (disorder) with optional seqovl
			local seqovl = tonumber(desync.arg.seqovl) or 0
			local seqovl_pat = desync.arg.seqovl_pattern and blob(desync, desync.arg.seqovl_pattern) or "\x00"

			for i=#parts,1,-1 do
				local part_data = parts[i][1]
				local part_offset = parts[i][2]

				-- Apply seqovl to second part (in original order, which is second-to-last in disorder)
				if i == (#parts - 1) and seqovl > 0 and part_offset >= seqovl then
					part_data = pattern(seqovl_pat, 1, seqovl) .. part_data
					part_offset = part_offset - seqovl
					if b_debug then DLOG("tls_aggressive: applied seqovl="..seqovl.." to part "..i) end
				end

				if b_debug then DLOG("tls_aggressive: sending part "..i.." offset="..part_offset.." len="..#part_data) end
				if not rawsend_payload_segmented(desync, part_data, part_offset, opts_orig) then
					return VERDICT_PASS
				end
			end

			-- STEP 4: Send trailing fakes (sandwich)
			for i=1,math.floor(num_fakes/2) do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				if fake_dis.ip then
					fake_dis.ip.ip_ttl = ttl_start
				end
				if fake_dis.ip6 then
					fake_dis.ip6.ip6_hlim = ttl_start
				end
				if fake_dis.tcp and desync.arg.badseq then
					fake_dis.tcp.th_ack = fake_dis.tcp.th_ack - 66000
				end
				if b_debug then DLOG("tls_aggressive: sending trailing fake #"..i) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("tls_aggressive: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- TLS with extreme multi-split at SNI and surrounding areas
-- Splits TLS Client Hello into many small pieces around SNI
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : seqovl=N - sequence overlap (default 211)
-- arg : seqovl_pattern=<blob> - pattern for seqovl
function tls_multisplit_sni(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			-- Get extensive split positions around SNI
			local spos = "1,host-2,host,host+1,host+2,midsld-1,midsld,midsld+1,sld,sld+1,sld+2,endhost-2,endhost-1,endhost,sniext,sniext+1,sniext+2"

			if b_debug then DLOG("tls_multisplit_sni: split pos: "..spos) end
			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("tls_multisplit_sni: resolved split pos: "..table.concat(zero_based_pos(pos)," ")) end
			delete_pos_1(pos)

			if #pos>0 then
				local seqovl = tonumber(desync.arg.seqovl) or 211
				local seqovl_pat = desync.arg.seqovl_pattern and blob(desync, desync.arg.seqovl_pattern) or blob(desync, "fake_default_tls")

				-- Send in disorder order (last to first)
				for i=#pos,0,-1 do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part = string.sub(data,pos_start,pos_end)
					local part_seqovl = 0

					-- Apply seqovl to second part (in original order)
					if i==1 and seqovl > 0 then
						part_seqovl = seqovl
						if part_seqovl >= (pos[1]-1) then
							DLOG("tls_multisplit_sni: seqovl cancelled, too large")
							part_seqovl = 0
						else
							part = pattern(seqovl_pat, 1, part_seqovl) .. part
						end
					end

					if b_debug then DLOG("tls_multisplit_sni: sending part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..part_seqovl) end
					if not rawsend_payload_segmented(desync, part, pos_start-1-part_seqovl) then
						return VERDICT_PASS
					end
				end
				replay_drop_set(desync)
				return VERDICT_DROP
			else
				DLOG("tls_multisplit_sni: no valid split positions")
			end
		else
			DLOG("tls_multisplit_sni: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- TLS Fake flood + standard multidisorder
-- Sends many fakes before applying standard multidisorder
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : fakes=N - number of fakes (default 11)
-- arg : pos=<posmarker list> - split positions for multidisorder
-- arg : badseq/md5sig - fooling for fakes
function tls_fake_flood(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 11
			local fake_blob = desync.arg.blob and blob(desync, desync.arg.blob) or blob(desync, "fake_default_tls")

			-- Apply tls_mod to make fake look real but with different SNI
			local fake_data = tls_mod(fake_blob, "rnd,dupsid,sni=www.google.com", desync.reasm_data)

			local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync)}

			-- Send fake flood with varying TTL
			for i=1,num_fakes do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data

				-- Vary TTL: 1,2,3,1,2,3,1,2,3...
				local ttl = ((i-1) % 3) + 1
				if fake_dis.ip then fake_dis.ip.ip_ttl = ttl end
				if fake_dis.ip6 then fake_dis.ip6.ip6_hlim = ttl end

				-- Apply fooling
				if fake_dis.tcp then
					if desync.arg.badseq then
						fake_dis.tcp.th_ack = fake_dis.tcp.th_ack - 66000
					end
					if desync.arg.md5sig then
						-- md5sig applied through reconstruct
					end
				end

				if b_debug then DLOG("tls_fake_flood: sending fake #"..i.." TTL="..ttl) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			-- Now send real data with multidisorder
			local spos = desync.arg.pos or "1,midsld"
			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			delete_pos_1(pos)

			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				ipid = desync.arg,
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}

			if #pos>0 then
				for i=#pos,0,-1 do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part = string.sub(data,pos_start,pos_end)

					if b_debug then DLOG("tls_fake_flood: sending part "..(i+1).." len="..#part) end
					if not rawsend_payload_segmented(desync, part, pos_start-1, opts_orig) then
						return VERDICT_PASS
					end
				end
			else
				-- No valid positions, send as-is
				if not rawsend_payload_segmented(desync, data, 0, opts_orig) then
					return VERDICT_PASS
				end
			end

			-- Send more fakes after (sandwich)
			for i=1,math.floor(num_fakes/3) do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				if fake_dis.ip then fake_dis.ip.ip_ttl = 1 end
				if fake_dis.ip6 then fake_dis.ip6.ip6_hlim = 1 end
				if b_debug then DLOG("tls_fake_flood: sending trailing fake #"..i) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("tls_fake_flood: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- ============================================================================
-- SOFT/GENTLE TLS STRATEGIES - less aggressive, won't break sites
-- ============================================================================

-- Simple fake only - no splitting, just send fakes before real data
-- Works for many sites without breaking TLS
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : fakes=N - number of fakes (default 6)
-- arg : ttl=N - TTL for fakes (default 3)
-- arg : sni=<str> - SNI for fakes (default www.google.com)
function tls_fake_simple(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 6
			local ttl = tonumber(desync.arg.ttl) or 3
			local fake_sni = desync.arg.sni or "www.google.com"

			local fake_blob = desync.arg.blob and blob(desync, desync.arg.blob) or blob(desync, "fake_default_tls")
			local fake_data = tls_mod(fake_blob, "rnd,dupsid,sni="..fake_sni, desync.reasm_data)

			local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync)}

			-- Send fakes
			for i=1,num_fakes do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				if fake_dis.ip then fake_dis.ip.ip_ttl = ttl end
				if fake_dis.ip6 then fake_dis.ip6.ip6_hlim = ttl end

				if b_debug then DLOG("tls_fake_simple: sending fake #"..i.." TTL="..ttl) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			-- Send real data as-is (no splitting!)
			DLOG("tls_fake_simple: sending real data len="..#data)
			-- Don't drop, let original packet through
		else
			DLOG("tls_fake_simple: not acting on further replay pieces")
		end
	end
end


-- Gentle split - only 2 parts, no disorder
-- Splits at midsld position only
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : pos=<posmarker> - single split position (default midsld)
function tls_split_gentle(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "midsld"
			local pos = resolve_pos(data, desync.l7payload, spos)

			if pos and pos > 1 and pos < #data then
				if b_debug then DLOG("tls_split_gentle: split at "..spos.." = "..(pos-1)) end

				local opts_orig = {
					rawsend = rawsend_opts_base(desync),
					reconstruct = {},
					ipfrag = {},
					ipid = desync.arg,
					fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
				}

				-- Part 1: start to split pos
				local part1 = string.sub(data, 1, pos-1)
				if b_debug then DLOG("tls_split_gentle: sending part 1 len="..#part1) end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then
					return VERDICT_PASS
				end

				-- Part 2: split pos to end
				local part2 = string.sub(data, pos)
				if b_debug then DLOG("tls_split_gentle: sending part 2 len="..#part2) end
				if not rawsend_payload_segmented(desync, part2, pos-1, opts_orig) then
					return VERDICT_PASS
				end

				replay_drop_set(desync)
				return VERDICT_DROP
			else
				DLOG("tls_split_gentle: cannot resolve pos '"..spos.."' or invalid")
			end
		else
			DLOG("tls_split_gentle: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- Fake + gentle split combo
-- Send fakes then split at one position
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : fakes=N - number of fakes (default 4)
-- arg : ttl=N - TTL for fakes (default 2)
-- arg : pos=<posmarker> - split position (default midsld)
function tls_fake_split(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 4
			local ttl = tonumber(desync.arg.ttl) or 2
			local spos = desync.arg.pos or "midsld"

			local fake_blob = desync.arg.blob and blob(desync, desync.arg.blob) or blob(desync, "fake_default_tls")
			local fake_data = tls_mod(fake_blob, "rnd,dupsid,sni=www.google.com", desync.reasm_data)

			local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync)}
			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				ipid = desync.arg,
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}

			-- Send fakes first
			for i=1,num_fakes do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				if fake_dis.ip then fake_dis.ip.ip_ttl = ttl end
				if fake_dis.ip6 then fake_dis.ip6.ip6_hlim = ttl end
				if b_debug then DLOG("tls_fake_split: sending fake #"..i) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			-- Now split at one position
			local pos = resolve_pos(data, desync.l7payload, spos)
			if pos and pos > 1 and pos < #data then
				local part1 = string.sub(data, 1, pos-1)
				local part2 = string.sub(data, pos)

				if b_debug then DLOG("tls_fake_split: sending part 1 len="..#part1) end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then
					return VERDICT_PASS
				end

				if b_debug then DLOG("tls_fake_split: sending part 2 len="..#part2) end
				if not rawsend_payload_segmented(desync, part2, pos-1, opts_orig) then
					return VERDICT_PASS
				end

				replay_drop_set(desync)
				return VERDICT_DROP
			else
				-- Can't split, send as-is
				DLOG("tls_fake_split: can't split, sending as-is")
				if not rawsend_payload_segmented(desync, data, 0, opts_orig) then
					return VERDICT_PASS
				end
				replay_drop_set(desync)
				return VERDICT_DROP
			end
		else
			DLOG("tls_fake_split: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- Disorder with only 3 parts (gentle)
-- Less fragmentation = works with more servers
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : pos1=<posmarker> - first split (default host)
-- arg : pos2=<posmarker> - second split (default endhost)
function tls_disorder_gentle(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local spos1 = desync.arg.pos1 or "host"
			local spos2 = desync.arg.pos2 or "endhost"

			local pos1 = resolve_pos(data, desync.l7payload, spos1)
			local pos2 = resolve_pos(data, desync.l7payload, spos2)

			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				ipid = desync.arg,
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}

			if pos1 and pos2 and pos1 > 1 and pos2 > pos1 and pos2 <= #data then
				if b_debug then DLOG("tls_disorder_gentle: split at "..spos1.."="..(pos1-1)..", "..spos2.."="..(pos2-1)) end

				local part1 = string.sub(data, 1, pos1-1)
				local part2 = string.sub(data, pos1, pos2-1)
				local part3 = string.sub(data, pos2)

				-- Send in disorder: 3, 2, 1
				if b_debug then DLOG("tls_disorder_gentle: sending part 3 (last) len="..#part3) end
				if not rawsend_payload_segmented(desync, part3, pos2-1, opts_orig) then
					return VERDICT_PASS
				end

				if b_debug then DLOG("tls_disorder_gentle: sending part 2 (middle) len="..#part2) end
				if not rawsend_payload_segmented(desync, part2, pos1-1, opts_orig) then
					return VERDICT_PASS
				end

				if b_debug then DLOG("tls_disorder_gentle: sending part 1 (first) len="..#part1) end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then
					return VERDICT_PASS
				end

				replay_drop_set(desync)
				return VERDICT_DROP
			else
				DLOG("tls_disorder_gentle: can't resolve positions, falling back to simple split")
				-- Fallback: split at position 2
				local part1 = string.sub(data, 1, 1)
				local part2 = string.sub(data, 2)

				-- Disorder: 2, 1
				if not rawsend_payload_segmented(desync, part2, 1, opts_orig) then
					return VERDICT_PASS
				end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then
					return VERDICT_PASS
				end

				replay_drop_set(desync)
				return VERDICT_DROP
			end
		else
			DLOG("tls_disorder_gentle: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- ============================================================================
-- MGTS HTTP BYPASS STRATEGIES: optimized for MGTS DPI
-- ============================================================================

-- HTTP seqovl Host Override
-- Send fake Host with seqovl, then real Host that overwrites it
-- DPI inspects fake Host first; server accepts real Host via TCP reassembly
-- standard args : direction, payload, rawsend, reconstruct
-- arg : fake_host=<str> - fake host name (default google.com)
-- arg : seqovl=N - overlap size (default = length of Host value)
function http_seqovl_host(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local hdis = http_dissect_req(data)
			local host_idx = hdis and array_field_search(hdis.headers, "header_low", "host")
			if not host_idx then
				DLOG("http_seqovl_host: no Host header found")
				return
			end

			local host_pos = hdis.headers[host_idx]
			local real_host = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
			local fake_host = desync.arg.fake_host or "google.com"

			DLOG("http_seqovl_host: real_host='"..real_host.."' fake_host='"..fake_host.."'")

			-- Build fake HTTP request with fake_host
			-- Match lengths of fake_host and real_host for exact seqovl alignment
			if #fake_host < #real_host then
				fake_host = fake_host .. string.rep("x", #real_host - #fake_host)
			elseif #fake_host > #real_host then
				fake_host = string.sub(fake_host, 1, #real_host)
			end

			local fake_data = string.sub(data, 1, host_pos.pos_value_start-1) ..
							  fake_host ..
							  string.sub(data, host_pos.pos_end+1)

			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				fooling = {}
			}

			-- Host value start position
			local host_value_pos = host_pos.pos_value_start - 1  -- 0-based

			-- STEP 1: Send portion before Host value
			local before_host = string.sub(data, 1, host_pos.pos_value_start-1)
			if b_debug then DLOG("http_seqovl_host: sending before_host len="..#before_host) end
			if not rawsend_payload_segmented(desync, before_host, 0, opts_orig) then
				return VERDICT_PASS
			end

			-- STEP 2: Send FAKE Host value (DPI sees this first)
			if b_debug then DLOG("http_seqovl_host: sending FAKE host '"..fake_host.."'") end
			if not rawsend_payload_segmented(desync, fake_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end

			-- STEP 3: Send REAL Host value at same offset (seqovl)
			-- Server TCP stack reassembles and overwrites fake bytes
			if b_debug then DLOG("http_seqovl_host: sending REAL host '"..real_host.."' (seqovl)") end
			if not rawsend_payload_segmented(desync, real_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end

			-- STEP 4: Send remainder after Host value
			local after_host = string.sub(data, host_pos.pos_end+1)
			if b_debug then DLOG("http_seqovl_host: sending after_host len="..#after_host) end
			if not rawsend_payload_segmented(desync, after_host, host_pos.pos_end, opts_orig) then
				return VERDICT_PASS
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("http_seqovl_host: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- HTTP with IP fragmentation
-- Fragment IP packets to evade DPI without fragment reassembly
-- standard args : direction, payload, rawsend
-- arg : frag_size=N - first fragment size (default 24: splits inside Host)
function http_ipfrag(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local frag_size = tonumber(desync.arg.frag_size) or 24

			DLOG("http_ipfrag: fragmenting at IP level, frag_size="..frag_size)

			-- Use native IP fragmentation
			local opts = {
				rawsend = rawsend_opts(desync),
				reconstruct = {},
				ipfrag = {
					ipfrag_pos_tcp = frag_size
				}
			}

			if rawsend_dissect_ipfrag(desync.dis, opts) then
				replay_drop_set(desync)
				return VERDICT_DROP
			end
		else
			DLOG("http_ipfrag: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- HTTP Host case modification
-- Alter case in "Host:" header for case-sensitive DPI parsers
-- standard args : direction, payload
-- arg : case=<str> - "lower", "upper", "mixed", "space" (default mixed)
function http_hostmod(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	if desync.l7payload=="http_req" and direction_check(desync) then
		local case_type = desync.arg.case or "mixed"
		local new_host_header

		if case_type == "lower" then
			new_host_header = "host"
		elseif case_type == "upper" then
			new_host_header = "HOST"
		elseif case_type == "mixed" then
			new_host_header = "HoSt"
		elseif case_type == "space" then
			new_host_header = "Host "  -- trailing space
		elseif case_type == "tab" then
			new_host_header = "Host\t"  -- trailing tab
		else
			new_host_header = case_type  -- custom
		end

		-- Find and replace "Host:" header variant
		local host_start = string.find(desync.dis.payload, "\r\nHost:", 1, true)
		if host_start then
			host_start = host_start + 2  -- skip \r\n
			local new_payload = string.sub(desync.dis.payload, 1, host_start-1) ..
							   new_host_header .. ":" ..
							   string.sub(desync.dis.payload, host_start + 5)  -- skip "Host:"
			desync.dis.payload = new_payload
			DLOG("http_hostmod: changed 'Host:' to '"..new_host_header..":' ")
			return VERDICT_MODIFY
		else
			DLOG("http_hostmod: Host header not found")
		end
	end
end


-- HTTP Triple seqovl attack
-- Send 3 versions of Host value with identical seq number:
-- 1. Fake host (cached by DPI)
-- 2. Garbage (disrupts DPI state)
-- 3. Real host (accepted last by server)
-- standard args : direction, payload, rawsend, reconstruct
-- arg : fake_host=<str> - fake host
function http_triple_seqovl(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local hdis = http_dissect_req(data)
			local host_idx = hdis and array_field_search(hdis.headers, "header_low", "host")
			if not host_idx then
				DLOG("http_triple_seqovl: no Host header")
				return
			end

			local host_pos = hdis.headers[host_idx]
			local real_host = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
			local host_len = #real_host
			local fake_host = desync.arg.fake_host or "www.google.com"

			-- Align length
			if #fake_host < host_len then
				fake_host = fake_host .. string.rep(".", host_len - #fake_host)
			else
				fake_host = string.sub(fake_host, 1, host_len)
			end

			local garbage = string.rep("X", host_len)

			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				fooling = {}
			}

			local host_value_pos = host_pos.pos_value_start - 1

			-- Send portion before Host value
			local before_host = string.sub(data, 1, host_pos.pos_value_start-1)
			if not rawsend_payload_segmented(desync, before_host, 0, opts_orig) then
				return VERDICT_PASS
			end

			-- ATTACK: 3 packets with matching seq
			-- 1. Fake host
			if b_debug then DLOG("http_triple_seqovl: [1] FAKE host '"..fake_host.."'") end
			if not rawsend_payload_segmented(desync, fake_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end

			-- 2. Garbage (invalidates DPI cache)
			if b_debug then DLOG("http_triple_seqovl: [2] GARBAGE") end
			if not rawsend_payload_segmented(desync, garbage, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end

			-- 3. Real host (accepted by server)
			if b_debug then DLOG("http_triple_seqovl: [3] REAL host '"..real_host.."'") end
			if not rawsend_payload_segmented(desync, real_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end

			-- Send remaining payload
			local after_host = string.sub(data, host_pos.pos_end+1)
			if not rawsend_payload_segmented(desync, after_host, host_pos.pos_end, opts_orig) then
				return VERDICT_PASS
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- HTTP Disorder + seqovl combo for MGTS
-- Combine disorder with seqovl targeted at Host header
-- standard args : direction, payload, rawsend
-- arg : fake_host=<str>
function http_mgts_combo(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local hdis = http_dissect_req(data)
			local host_idx = hdis and array_field_search(hdis.headers, "header_low", "host")
			if not host_idx then
				DLOG("http_mgts_combo: no Host header")
				return
			end

			local host_pos = hdis.headers[host_idx]
			local real_host = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
			local fake_host = desync.arg.fake_host or "www.google.com"

			-- Align length
			local host_len = #real_host
			if #fake_host < host_len then
				fake_host = fake_host .. string.rep("x", host_len - #fake_host)
			else
				fake_host = string.sub(fake_host, 1, host_len)
			end

			local opts = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				fooling = {}
			}

			-- Split into 4 parts:
			-- 1. Pre-"Host:"
			-- 2. "Host: " + fake_host (seqovl overlap)
			-- 3. real_host (overwrites fake)
			-- 4. Post-host value to end

			local part1 = string.sub(data, 1, host_pos.pos_start - 1)  -- pre-Host:
			local part2_fake = "Host: " .. fake_host
			local part3_real = real_host
			local part4 = string.sub(data, host_pos.pos_end + 1)  -- post-Host value

			local pos_host_start = host_pos.pos_start - 1  -- 0-based
			local pos_host_value = host_pos.pos_value_start - 1
			local pos_after_host = host_pos.pos_end  -- 0-based offset after host

			-- DISORDER: send segments in reverse order
			-- 4 -> 3 -> 2 -> 1

			if b_debug then DLOG("http_mgts_combo: [4] after_host len="..#part4) end
			if not rawsend_payload_segmented(desync, part4, pos_after_host, opts) then
				return VERDICT_PASS
			end

			-- Real host (accepted by server)
			if b_debug then DLOG("http_mgts_combo: [3] REAL '"..part3_real.."'") end
			if not rawsend_payload_segmented(desync, part3_real, pos_host_value, opts) then
				return VERDICT_PASS
			end

			-- Fake "Host: fake" with seqovl (seen by DPI)
			if b_debug then DLOG("http_mgts_combo: [2] FAKE '"..part2_fake.."' (seqovl)") end
			if not rawsend_payload_segmented(desync, part2_fake, pos_host_start, opts) then
				return VERDICT_PASS
			end

			-- Request prefix
			if b_debug then DLOG("http_mgts_combo: [1] before_host len="..#part1) end
			if not rawsend_payload_segmented(desync, part1, 0, opts) then
				return VERDICT_PASS
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


-- Combined: Fake + gentle disorder
-- Best of both: fakes confuse DPI, gentle disorder doesn't break server
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : fakes=N - number of fakes (default 3)
-- arg : ttl=N - TTL for fakes (default 2)
function tls_fake_disorder_gentle(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)

	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 3
			local ttl = tonumber(desync.arg.ttl) or 2

			local fake_blob = desync.arg.blob and blob(desync, desync.arg.blob) or blob(desync, "fake_default_tls")
			local fake_data = tls_mod(fake_blob, "rnd,dupsid,sni=www.google.com", desync.reasm_data)

			local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync)}
			local opts_orig = {
				rawsend = rawsend_opts_base(desync),
				reconstruct = {},
				ipfrag = {},
				ipid = desync.arg,
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}

			-- Send fakes
			for i=1,num_fakes do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				if fake_dis.ip then fake_dis.ip.ip_ttl = ttl end
				if fake_dis.ip6 then fake_dis.ip6.ip6_hlim = ttl end
				if b_debug then DLOG("tls_fake_disorder_gentle: sending fake #"..i) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end

			-- Gentle disorder: split at host and endhost only
			local pos1 = resolve_pos(data, desync.l7payload, "host")
			local pos2 = resolve_pos(data, desync.l7payload, "endhost")

			if pos1 and pos2 and pos1 > 1 and pos2 > pos1 and pos2 <= #data then
				local part1 = string.sub(data, 1, pos1-1)
				local part2 = string.sub(data, pos1, pos2-1)
				local part3 = string.sub(data, pos2)

				-- Disorder: 3, 2, 1
				if not rawsend_payload_segmented(desync, part3, pos2-1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part2, pos1-1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			else
				-- Fallback: just split at position 2
				local part1 = string.sub(data, 1, 1)
				local part2 = string.sub(data, 2)
				if not rawsend_payload_segmented(desync, part2, 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			end

			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("tls_fake_disorder_gentle: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end


--[[
    multisplit_tls - multisplit with dynamic TLS pattern generation

    Generates fake TLS on the fly via tls_mod with target SNI (e.g. www.google.com)
    instead of using a static seqovl_pattern file.

    IMPORTANT: If payload is not valid TLS, tls_mod is bypassed and fallback pattern
    is used, or packet is passed through unmodified.

    Arguments:
        pos         - split positions: "2", "1,midsld", etc.
        seqovl      - overlap size in bytes (recommended: 650-700)
        sni         - fake TLS SNI (default: "www.google.com")
        tls_rnd     - randomize random/session_id in fake TLS
        tls_dupsid  - duplicate session_id from real packet
        nodrop      - do not drop original packet
        fallback    - non-TLS payload handling: "pass", "split", "pattern"

    Example:
        --lua-desync=multisplit_tls:seqovl=680:sni=www.google.com:tls_rnd:tls_dupsid:pos=2

┌─────────────────────────────────────────────────────────────────┐
│                    HOW SEQOVL WORKS                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Normal packet:    [TLS ClientHello with real SNI]              │
│                     seq=1000, len=500                           │
│                                                                 │
│  With seqovl=650:  [FAKE TLS (650 bytes)][Real TLS]             │
│                     seq=350, len=1150                           │
│                                                                 │
│  TSPU sees:        SNI from FAKE TLS (www.google.com)           │
│  Server receives:  Real TLS (TSPU cannot block)                 │
│                                                                 │
│  Why? TCP overlap - server favors data with higher sequence num │
└─────────────────────────────────────────────────────────────────┘
--]]

-- Helper: validate TLS ClientHello record
local function is_valid_tls_client_hello(data)
    if not data or #data < 6 then
        return false
    end

    -- TLS Record Header: ContentType (1 byte) + Version (2 bytes) + Length (2 bytes)
    -- ContentType = 0x16 (Handshake)
    -- Version = 0x0301 (TLS 1.0), 0x0302 (TLS 1.1), 0x0303 (TLS 1.2), 0x0304 (TLS 1.3)
    local content_type = string.byte(data, 1)
    local version_major = string.byte(data, 2)
    local version_minor = string.byte(data, 3)

    -- Verify Handshake record type
    if content_type ~= 0x16 then
        return false
    end

    -- Verify TLS version (0x03 0x01-0x04)
    if version_major ~= 0x03 then
        return false
    end

    if version_minor < 0x01 or version_minor > 0x04 then
        return false
    end

    -- Verify Handshake Type (0x01 = ClientHello)
    -- Handshake header starts at byte offset 6 (past 5-byte TLS record header)
    if #data >= 6 then
        local handshake_type = string.byte(data, 6)
        if handshake_type ~= 0x01 then
            return false
        end
    end

    return true
end
function multisplit_tls(ctx, desync)
    -- TCP only
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync)

    -- Retrieve reassembled TLS or raw payload
    local data = desync.reasm_data or desync.dis.payload

    -- ============================================
    -- GUARD: Bypass MTProto and Telegram traffic
    -- seqovl breaks Telegram connections
    -- ============================================

    -- 1. Bypass MTProto (non-TLS protocol broken by seqovl)
    if desync.l7payload == "mtproto_initial" or desync.l7payload == "mtproto" then
        if b_debug then
            DLOG("multisplit_tls: SKIP MTProto traffic - not compatible with seqovl")
        end
        return  -- Pass packet unmodified
    end

    -- 2. Bypass Telegram domains
    if desync.hostname then
        local telegram_domains = {
            "telegram.org",
            "t.me",
            "telegram.me",
            "tdesktop.com",
            "telegra.ph"
        }
        for _, domain in ipairs(telegram_domains) do
            if string.find(desync.hostname, domain, 1, true) then
                if b_debug then
                    DLOG("multisplit_tls: SKIP Telegram domain: " .. desync.hostname)
                end
                return  -- Pass packet unmodified
            end
        end
    end

    -- Verify packet direction and payload requirements
    if #data > 0 and direction_check(desync) and payload_check(desync) then
        if replay_first(desync) then
            -- Split positions (default "2" = after first payload byte)
            local spos = desync.arg.pos or "2"

            if b_debug then
                DLOG("multisplit_tls: split pos: " .. spos)
            end

            -- Resolve actual split offsets
            local pos = resolve_multi_pos(data, desync.l7payload, spos)

            if b_debug then
                DLOG("multisplit_tls: resolved: " .. table.concat(zero_based_pos(pos), " "))
            end

            -- Position 1 is invalid for split
            delete_pos_1(pos)

            if #pos > 0 then
                -- ============================================
                -- Check if payload is TLS
                -- ============================================
                local payload_is_tls = is_valid_tls_client_hello(data)
                local reasm_is_tls = desync.reasm_data and is_valid_tls_client_hello(desync.reasm_data)
                local can_apply_tls_mod = payload_is_tls or reasm_is_tls

                -- Check engine l7payload
                if desync.l7payload == "tls_client_hello" then
                    can_apply_tls_mod = true
                end

                if b_debug then
                    DLOG("multisplit_tls: payload_is_tls=" .. tostring(payload_is_tls) ..
                         " reasm_is_tls=" .. tostring(reasm_is_tls) ..
                         " l7payload=" .. tostring(desync.l7payload) ..
                         " can_apply_tls_mod=" .. tostring(can_apply_tls_mod))
                end

                -- Transmit packet segments
                for i = 0, #pos do
                    local pos_start = pos[i] or 1
                    local pos_end = i < #pos and pos[i + 1] - 1 or #data
                    local part = string.sub(data, pos_start, pos_end)
                    local seqovl = 0

                    -- SEQOVL applies to FIRST segment only (i == 0)
                    if i == 0 and desync.arg.seqovl and tonumber(desync.arg.seqovl) > 0 then
                        seqovl = tonumber(desync.arg.seqovl)

                        -- ============================================
                        -- Safe pattern generation
                        -- ============================================
                        local pat = nil

                        if can_apply_tls_mod then
                            -- TLS payload: apply tls_mod

                            -- Base fake TLS template (~680 bytes)
                            local base_tls = blob(desync, "fake_default_tls")

                            -- Collect modifications
                            local mods = {}

                            -- SNI (default www.google.com)
                            local sni = desync.arg.sni or "www.google.com"
                            table.insert(mods, "sni=" .. sni)

                            -- Randomize random bytes and session_id
                            if desync.arg.tls_rnd then
                                table.insert(mods, "rnd")
                            end

                            -- Copy session_id from real packet
                            -- ONLY when reasm_data is valid TLS
                            if desync.arg.tls_dupsid and reasm_is_tls then
                                table.insert(mods, "dupsid")
                            elseif desync.arg.tls_dupsid and not reasm_is_tls then
                                -- dupsid requested on non-TLS reasm_data: skip
                                if b_debug then
                                    DLOG("multisplit_tls: skipping dupsid - reasm_data is not valid TLS")
                                end
                            end

                            local modlist = table.concat(mods, ",")

                            if b_debug then
                                DLOG("multisplit_tls: applying tls_mod: " .. modlist)
                            end

                            -- Apply modifications to fake TLS
                            -- Third parameter is real TLS packet for dupsid
                            local reasm_for_mod = reasm_is_tls and desync.reasm_data or nil
                            local fake_tls = tls_mod(base_tls, modlist, reasm_for_mod)

                            if fake_tls and #fake_tls > 0 then
                                -- Build pattern of requested length (seqovl bytes)
                                pat = pattern(fake_tls, 1, seqovl)

                                if b_debug then
                                    DLOG("multisplit_tls: seqovl=" .. seqovl ..
                                         " fake_tls_len=" .. #fake_tls ..
                                         " sni=" .. sni)
                                end
                            else
                                -- tls_mod returned empty: fallback
                                if b_debug then
                                    DLOG("multisplit_tls: tls_mod returned empty, using raw blob")
                                end
                                pat = pattern(base_tls, 1, seqovl)
                            end
                        else
                            -- ============================================
                            -- NON-TLS PAYLOAD: FALLBACK
                            -- ============================================
                            local fallback_mode = desync.arg.fallback or "pass"

                            if b_debug then
                                DLOG("multisplit_tls: payload is NOT valid TLS, fallback=" .. fallback_mode)
                            end

                            if fallback_mode == "pass" then
                                -- Pass packet unmodified
                                DLOG("multisplit_tls: fallback=pass, letting packet through unchanged")
                                return VERDICT_PASS

                            elseif fallback_mode == "split" then
                                -- Split without seqovl
                                DLOG("multisplit_tls: fallback=split, splitting without seqovl")
                                seqovl = 0
                                -- pat remains nil, seqovl = 0 (plain split)

                            else  -- "pattern" or fallback
                                -- Raw blob without tls_mod modifications
                                -- Safe raw bytes prepended before packet
                                local raw_blob = blob(desync, "fake_default_tls")
                                if raw_blob and #raw_blob > 0 then
                                    pat = pattern(raw_blob, 1, seqovl)
                                    DLOG("multisplit_tls: fallback=pattern, using raw blob without tls_mod")
                                else
                                    -- Blob unavailable: plain split without seqovl
                                    DLOG("multisplit_tls: no blob available, splitting without seqovl")
                                    seqovl = 0
                                end
                            end
                        end

                        -- Prepend pattern before real payload
                        if pat and #pat > 0 then
                            part = pat .. part
                        else
                            -- No pattern available: reset seqovl
                            seqovl = 0
                        end
                    end

                    if b_debug then
                        DLOG("multisplit_tls: sending part " .. (i + 1) ..
                             " pos=" .. (pos_start - 1) .. "-" .. (pos_end - 1) ..
                             " len=" .. #part .. " seqovl=" .. seqovl)
                    end

                    -- Send segment with decremented sequence number (overlap)
                    if not rawsend_payload_segmented(desync, part, pos_start - 1 - seqovl) then
                        return VERDICT_PASS
                    end
                end

                replay_drop_set(desync)
                return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
            else
                DLOG("multisplit_tls: no valid split positions")
            end
        else
            DLOG("multisplit_tls: not acting on further replay pieces")
        end

        -- Drop replayed packets after successful split transmission
        if replay_drop(desync) then
            return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
        end
    end
end


-- HTTP Method Obfuscation
-- Evades DPI parsing standard GET/POST methods only
-- standard args : direction, payload
-- arg : method=<str> - "lowercase", "padding", "fake" (default lowercase)
function http_method_obfuscate(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)

    if desync.l7payload=="http_req" and direction_check(desync) then
        local mode = desync.arg.method or "lowercase"
        local payload = desync.dis.payload

        if mode == "lowercase" then
            -- Lowercase method: GET -> get
            payload = string.gsub(payload, "^GET ", "get ")
            payload = string.gsub(payload, "^POST ", "post ")
            payload = string.gsub(payload, "^HEAD ", "head ")
        elseif mode == "padding" then
            -- Extra spaces: GET -> GET (extra trailing spaces)
            payload = string.gsub(payload, "^GET ", "GET  ")
            payload = string.gsub(payload, "^POST ", "POST  ")
        elseif mode == "fake" then
            -- Prepend fake method before real method
            payload = "X " .. payload
        elseif mode == "case" then
            -- GET -> GeT
            payload = string.gsub(payload, "^GET ", "GeT ")
            payload = string.gsub(payload, "^POST ", "PoSt ")
        end

        desync.dis.payload = payload
        DLOG("http_method_obfuscate: applied mode '"..mode.."'")
        return VERDICT_MODIFY
    end
end


-- HTTP Split At Host Byte
-- Splits Host value into byte-sized segments with transmission delay
-- standard args : direction, payload, rawsend
-- arg : max_parts=N - max segments for Host value (default 5)
function http_host_bytesplit(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff(ctx)
        return
    end
    direction_cutoff_opposite(ctx, desync)

    local data = desync.reasm_data or desync.dis.payload
    if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
        if replay_first(desync) then
            local hdis = http_dissect_req(data)
            local host_idx = hdis and array_field_search(hdis.headers, "header_low", "host")
            if not host_idx then
                DLOG("http_host_bytesplit: no Host header")
                return
            end

            local host_pos = hdis.headers[host_idx]
            local max_parts = tonumber(desync.arg.max_parts) or 5

            local opts = {
                rawsend = rawsend_opts_base(desync),
                reconstruct = {},
                ipfrag = {},
                fooling = {}
            }

            -- Segment 1: Pre-Host value
            local before = string.sub(data, 1, host_pos.pos_value_start - 1)
            if b_debug then DLOG("http_host_bytesplit: [1] before len="..#before) end
            if not rawsend_payload_segmented(desync, before, 0, opts) then
                return VERDICT_PASS
            end

            -- Segments 2..N: Host value chunks
            local host_value = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
            local chunk_size = math.max(1, math.floor(#host_value / max_parts))
            local pos = 0
            local part_num = 2

            while pos < #host_value do
                local chunk_end = math.min(pos + chunk_size, #host_value)
                local chunk = string.sub(host_value, pos + 1, chunk_end)
                local offset = host_pos.pos_value_start - 1 + pos

                if b_debug then DLOG("http_host_bytesplit: ["..part_num.."] chunk='"..chunk.."'") end
                if not rawsend_payload_segmented(desync, chunk, offset, opts) then
                    return VERDICT_PASS
                end

                pos = chunk_end
                part_num = part_num + 1
            end

            -- Final segment: Post-Host value
            local after = string.sub(data, host_pos.pos_end + 1)
            if b_debug then DLOG("http_host_bytesplit: ["..part_num.."] after len="..#after) end
            if not rawsend_payload_segmented(desync, after, host_pos.pos_end, opts) then
                return VERDICT_PASS
            end

            replay_drop_set(desync)
            return VERDICT_DROP
        end

        if replay_drop(desync) then
            return VERDICT_DROP
        end
    end
end


-- HTTP Version Downgrade
-- Downgrades HTTP version for DPI lacking legacy support
-- standard args : direction, payload
-- arg : version=<str> - "1.0" or "0.9" (default 1.0)
function http_version_downgrade(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)

    if desync.l7payload=="http_req" and direction_check(desync) then
        local version = desync.arg.version or "1.0"
        local payload = desync.dis.payload

        if version == "1.0" or version == "0.9" then
            -- HTTP/1.0 preserves exact 8-byte length, maintaining TCP sequence numbers
            payload = string.gsub(payload, "HTTP/1.1", "HTTP/1.0")
        end

        desync.dis.payload = payload
        DLOG("http_version_downgrade: changed to HTTP/"..version)
        return VERDICT_MODIFY
    end
end


-- ============================================================================
-- DISCORD BYPASS STRATEGIES: Experimental DPI evasion techniques
-- Author: lua-strategy-creator agent
-- ============================================================================

--[[
Name: discord_window_collapse
Description: Window=0 attack to reset DPI session state.
             Sends first segment, then ACK with Window=0.
             DPI sees zero window and drops session tracking on timeout,
             after which remaining payload is delivered.

Usage: --lua-desync=discord_window_collapse

Parameters:
  - pos: split position (default: "host" for TLS SNI)
  - delay: delay before sending second part in ms (optional)
]]
function discord_window_collapse(ctx, desync)
    -- Verify TCP protocol
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    -- Disable reverse direction processing
    direction_cutoff_opposite(ctx, desync, "out")

    -- Verify packet direction and payload type
    if not direction_check(desync, "out") then return end
    if not payload_check(desync, "tls_client_hello") then return end

    -- Process initial packet only
    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local data = desync.reasm_data or desync.dis.payload
    if #data < 10 then return end

    DLOG("discord_window_collapse: processing TLS Client Hello len="..#data)

    -- Determine split offset (default: SNI start)
    local split_marker = desync.arg.pos or "host"
    local split_pos = resolve_pos(data, desync.l7payload, split_marker)

    if not split_pos or split_pos <= 1 or split_pos >= #data then
        -- Fallback: split at offset 50 (past TLS record header)
        split_pos = math.min(50, math.floor(#data / 2))
        DLOG("discord_window_collapse: using fallback split_pos="..split_pos)
    else
        DLOG("discord_window_collapse: resolved '"..split_marker.."' to pos="..split_pos)
    end

    local base_seq = desync.dis.tcp.th_seq

    -- Packet transmission options
    local opts = {
        rawsend = rawsend_opts_base(desync),
        reconstruct = {},
        ipfrag = {},
        ipid = desync.arg,
        fooling = {}
    }

    -- STEP 1: Send initial data segment (pre-SNI)
    local part1 = string.sub(data, 1, split_pos - 1)
    local pkt1 = deepcopy(desync.dis)
    pkt1.payload = part1
    pkt1.tcp.th_flags = bitor(TH_ACK, TH_PSH)

    DLOG("discord_window_collapse: sending part1 len="..#part1)
    rawsend_dissect(pkt1, opts.rawsend, opts.reconstruct)

    -- STEP 2: Send ACK with Window=0 (buffer full signal)
    -- DPI enters connection stall tracking state
    local ack_pkt = deepcopy(desync.dis)
    ack_pkt.payload = ""
    ack_pkt.tcp.th_seq = base_seq + #part1
    ack_pkt.tcp.th_flags = TH_ACK
    ack_pkt.tcp.th_win = 0  -- Zero window

    DLOG("discord_window_collapse: sending Window=0 ACK")
    rawsend_dissect(ack_pkt, opts.rawsend, opts.reconstruct)

    -- STEP 3: Send Window Update (restore window)
    local update_pkt = deepcopy(desync.dis)
    update_pkt.payload = ""
    update_pkt.tcp.th_seq = base_seq + #part1
    update_pkt.tcp.th_flags = TH_ACK
    update_pkt.tcp.th_win = 65535  -- Restore window

    DLOG("discord_window_collapse: sending Window Update")
    rawsend_dissect(update_pkt, opts.rawsend, opts.reconstruct)

    -- STEP 4: Send second data segment (contains SNI)
    -- DPI session state has cleared or stalled
    local part2 = string.sub(data, split_pos)
    local pkt2 = deepcopy(desync.dis)
    pkt2.payload = part2
    pkt2.tcp.th_seq = base_seq + #part1
    pkt2.tcp.th_flags = bitor(TH_ACK, TH_PSH)

    DLOG("discord_window_collapse: sending part2 len="..#part2)
    rawsend_dissect(pkt2, opts.rawsend, opts.reconstruct)

    replay_drop_set(desync)
    return VERDICT_DROP
end


--[[
Name: discord_router_alert
Description: Appends IP Option Router Alert (type=148/0x94).
             Router-based hardware DPI often fast-paths Router Alert
             packets without deep inspection, as used by RSVP/IGMP.

Usage: --lua-desync=discord_router_alert

Parameters:
  - split: split payload into segments (default: false)
  - pos: split position if split=true
]]
function discord_router_alert(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync, "out")

    if not direction_check(desync, "out") then return end
    if not payload_check(desync, "tls_client_hello") then return end
    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local data = desync.reasm_data or desync.dis.payload
    if #data < 10 then return end

    DLOG("discord_router_alert: processing TLS len="..#data)

    -- Packet transmission options
    local opts = {
        rawsend = rawsend_opts_base(desync),
        reconstruct = {},
        ipfrag = {},
        ipid = desync.arg,
        fooling = {}
    }

    -- Construct IP Option Router Alert
    -- Format: Type(1) + Length(1) + Value(2)
    -- Type = 0x94 (148): copy on fragmentation + class 0 + number 20
    -- Length = 4
    -- Value = 0x0000 (Router shall examine packet)
    local router_alert_option = string.char(0x94, 0x04, 0x00, 0x00)

    if desync.dis.ip then
        -- IPv4: append Router Alert option
        local pkt = deepcopy(desync.dis)

        -- Append to existing IP options or create new option header
        if pkt.ip.options then
            pkt.ip.options = pkt.ip.options .. router_alert_option
        else
            pkt.ip.options = router_alert_option
        end

        -- IP header length expanded by option bytes;
        -- winws2 recalculates automatically during packet reconstruction

        DLOG("discord_router_alert: added Router Alert IP option")

        if desync.arg.split then
            -- Segment payload
            local split_marker = desync.arg.pos or "host"
            local split_pos = resolve_pos(data, desync.l7payload, split_marker) or math.floor(#data / 2)

            if split_pos > 1 and split_pos < #data then
                local base_seq = pkt.tcp.th_seq

                -- Segment 1 with Router Alert
                local pkt1 = deepcopy(pkt)
                pkt1.payload = string.sub(data, 1, split_pos - 1)
                rawsend_dissect(pkt1, opts.rawsend, opts.reconstruct)

                -- Segment 2 with Router Alert
                local pkt2 = deepcopy(pkt)
                pkt2.payload = string.sub(data, split_pos)
                pkt2.tcp.th_seq = base_seq + split_pos - 1
                rawsend_dissect(pkt2, opts.rawsend, opts.reconstruct)

                DLOG("discord_router_alert: sent 2 parts with Router Alert")
                replay_drop_set(desync)
                return VERDICT_DROP
            end
        end

        -- Send single packet with Router Alert
        rawsend_dissect(pkt, opts.rawsend, opts.reconstruct)
        replay_drop_set(desync)
        return VERDICT_DROP

    elseif desync.dis.ip6 then
        -- IPv6: Hop-by-Hop Options extension header with Router Alert
        -- Construct extension header
        local pkt = deepcopy(desync.dis)

        -- Hop-by-Hop Options Header with Router Alert
        -- Next Header (1) + Hdr Ext Len (1) + Options
        -- Router Alert Option: Type=5, Len=2, Value=0x0000
        local hop_by_hop_data = string.char(
            0x05, 0x02, 0x00, 0x00,  -- Router Alert option
            0x01, 0x00              -- PadN to 8-byte boundary
        )

        -- Insert Hop-by-Hop header immediately following IPv6 header
        insert_ip6_exthdr(pkt.ip6, 1, IPPROTO_HOPOPTS, hop_by_hop_data)
        fix_ip6_next(pkt.ip6, IPPROTO_TCP)

        DLOG("discord_router_alert: added IPv6 Hop-by-Hop Router Alert")
        rawsend_dissect(pkt, opts.rawsend, opts.reconstruct)
        replay_drop_set(desync)
        return VERDICT_DROP
    end
end


--[[
Name: discord_ecn_exploit
Description: ECN (Explicit Congestion Notification) flag evasion.
             ECE/CWR TCP flags with ECN bits in IP ToS force certain DPI
             engines to fast-path traffic requiring priority processing.

Usage: --lua-desync=discord_ecn_exploit

Parameters:
  - split: split payload into segments (default: true)
  - pos: split position
  - disorder: send segments out of order
]]
function discord_ecn_exploit(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync, "out")

    if not direction_check(desync, "out") then return end
    if not payload_check(desync, "tls_client_hello") then return end
    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local data = desync.reasm_data or desync.dis.payload
    if #data < 10 then return end

    DLOG("discord_ecn_exploit: processing TLS len="..#data)

    local opts = {
        rawsend = rawsend_opts_base(desync),
        reconstruct = {},
        ipfrag = {},
        ipid = desync.arg,
        fooling = {}
    }

    -- Apply ECN marking
    local function apply_ecn(pkt)
        -- TCP: set ECE (ECN-Echo) flag
        -- CWR set only in response
        pkt.tcp.th_flags = bitor(pkt.tcp.th_flags, TH_ECE)

        -- IP: set ECN bits in ToS / Traffic Class field
        -- ECN occupies low-order 2 bits of ToS
        -- 00 = Not-ECT, 01 = ECT(1), 10 = ECT(0), 11 = CE (Congestion Experienced)
        -- Set CE (11): Congestion Experienced
        if pkt.ip then
            -- Preserve DSCP (upper 6 bits), set ECN=CE (11)
            pkt.ip.ip_tos = bitor(bitand(pkt.ip.ip_tos, 0xFC), 0x03)
        elseif pkt.ip6 then
            -- IPv6: set ECN in Traffic Class low-order bits
            pkt.ip6.ip6_flow = bitor(bitand(pkt.ip6.ip6_flow, 0xFFCFFFFF), 0x00300000)
        end
    end

    local do_split = desync.arg.split ~= "false" and desync.arg.split ~= "0"

    if do_split then
        local split_marker = desync.arg.pos or "host"
        local split_pos = resolve_pos(data, desync.l7payload, split_marker)

        if not split_pos or split_pos <= 1 or split_pos >= #data then
            split_pos = math.min(50, math.floor(#data / 2))
        end

        local base_seq = desync.dis.tcp.th_seq
        local part1 = string.sub(data, 1, split_pos - 1)
        local part2 = string.sub(data, split_pos)

        local pkt1 = deepcopy(desync.dis)
        pkt1.payload = part1
        apply_ecn(pkt1)

        local pkt2 = deepcopy(desync.dis)
        pkt2.payload = part2
        pkt2.tcp.th_seq = base_seq + #part1
        apply_ecn(pkt2)

        if desync.arg.disorder then
            -- Transmit in reverse order (disorder)
            DLOG("discord_ecn_exploit: sending disorder with ECN, part2 first")
            rawsend_dissect(pkt2, opts.rawsend, opts.reconstruct)
            rawsend_dissect(pkt1, opts.rawsend, opts.reconstruct)
        else
            DLOG("discord_ecn_exploit: sending split with ECN")
            rawsend_dissect(pkt1, opts.rawsend, opts.reconstruct)
            rawsend_dissect(pkt2, opts.rawsend, opts.reconstruct)
        end
    else
        -- Unfragmented transmission with ECN marking
        local pkt = deepcopy(desync.dis)
        apply_ecn(pkt)
        DLOG("discord_ecn_exploit: sending single packet with ECN")
        rawsend_dissect(pkt, opts.rawsend, opts.reconstruct)
    end

    replay_drop_set(desync)
    return VERDICT_DROP
end


--[[
Name: discord_timestamp_travel
Description: TCP packet with timestamp from the past.
             DPI enforcing PAWS (Protection Against Wrapped Sequences)
             may discard the packet, while servers without strict PAWS
             accept it.

Usage: --lua-desync=discord_timestamp_travel

Parameters:
  - offset_sec: timestamp offset backward in seconds (default: 7200 = 2 hours)
  - split: split payload into segments
  - pos: split position
]]
function discord_timestamp_travel(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync, "out")

    if not direction_check(desync, "out") then return end
    if not payload_check(desync, "tls_client_hello") then return end
    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local data = desync.reasm_data or desync.dis.payload
    if #data < 10 then return end

    DLOG("discord_timestamp_travel: processing TLS len="..#data)

    local opts = {
        rawsend = rawsend_opts_base(desync),
        reconstruct = {},
        ipfrag = {},
        ipid = desync.arg,
        fooling = {}
    }

    -- Offset in milliseconds (TCP timestamp format)
    local offset_sec = tonumber(desync.arg.offset_sec) or 7200  -- 2 hours default
    local offset_ms = offset_sec * 1000

    -- Modify TCP Timestamp option
    local function modify_timestamp(pkt, time_offset)
        if not pkt.tcp.options then
            -- Generate timestamp option if absent
            -- Kind=8, Length=10, TSval(4 bytes), TSecr(4 bytes)
            local now = os.time() * 1000  -- Timestamp estimate
            local old_ts = now - time_offset
            -- Pack big-endian timestamp
            local tsval = string.char(
                bitand(bitright(old_ts, 24), 0xFF),
                bitand(bitright(old_ts, 16), 0xFF),
                bitand(bitright(old_ts, 8), 0xFF),
                bitand(old_ts, 0xFF)
            )
            local tsecr = string.char(0, 0, 0, 0)  -- TSecr = 0 for outbound
            pkt.tcp.options = {{kind = 8, data = tsval .. tsecr}}
            return true
        end

        -- Locate existing timestamp option
        local ts_idx = find_tcp_option(pkt.tcp.options, 8)
        if ts_idx then
            local opt = pkt.tcp.options[ts_idx]
            if opt.data and #opt.data >= 4 then
                -- Read TSval (first 4 bytes)
                local b1, b2, b3, b4 = string.byte(opt.data, 1, 4)
                local current_ts = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4

                -- Decrement timestamp into the past
                local new_ts = current_ts - time_offset
                if new_ts < 0 then new_ts = 0 end

                -- Repack modified TSval
                local new_tsval = string.char(
                    bitand(bitright(new_ts, 24), 0xFF),
                    bitand(bitright(new_ts, 16), 0xFF),
                    bitand(bitright(new_ts, 8), 0xFF),
                    bitand(new_ts, 0xFF)
                )

                -- Preserve TSecr (remaining 4 bytes)
                local tsecr = string.sub(opt.data, 5, 8)
                if #tsecr < 4 then tsecr = string.char(0,0,0,0) end

                opt.data = new_tsval .. tsecr
                DLOG("discord_timestamp_travel: modified TSval "..current_ts.." -> "..new_ts)
                return true
            end
        end
        return false
    end

    local do_split = desync.arg.split

    if do_split then
        local split_marker = desync.arg.pos or "host"
        local split_pos = resolve_pos(data, desync.l7payload, split_marker)

        if not split_pos or split_pos <= 1 or split_pos >= #data then
            split_pos = math.min(50, math.floor(#data / 2))
        end

        local base_seq = desync.dis.tcp.th_seq

        -- Segment 1: standard timestamp
        local pkt1 = deepcopy(desync.dis)
        pkt1.payload = string.sub(data, 1, split_pos - 1)

        -- Segment 2: past timestamp
        local pkt2 = deepcopy(desync.dis)
        pkt2.payload = string.sub(data, split_pos)
        pkt2.tcp.th_seq = base_seq + split_pos - 1
        modify_timestamp(pkt2, offset_ms)

        DLOG("discord_timestamp_travel: sending split with time-traveled timestamp")
        rawsend_dissect(pkt1, opts.rawsend, opts.reconstruct)
        rawsend_dissect(pkt2, opts.rawsend, opts.reconstruct)
    else
        -- Full packet with past timestamp
        local pkt = deepcopy(desync.dis)
        modify_timestamp(pkt, offset_ms)
        DLOG("discord_timestamp_travel: sending packet with old timestamp")
        rawsend_dissect(pkt, opts.rawsend, opts.reconstruct)
    end

    replay_drop_set(desync)
    return VERDICT_DROP
end


--[[
Name: discord_urgent_sni
Description: URG flag + Urgent Pointer pointing to middle of SNI.
             Out-of-band urgent pointer corrupts DPI state tracking
             by misaligning inspection boundaries.

Usage: --lua-desync=discord_urgent_sni

Parameters:
  - urgent_pos: urgent pointer position (default: "midsld")
  - urgent_byte: byte value for urgent data (default: 0x00)
]]
function discord_urgent_sni(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync, "out")

    if not direction_check(desync, "out") then return end
    if not payload_check(desync, "tls_client_hello") then return end
    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local data = desync.reasm_data or desync.dis.payload
    if #data < 10 then return end

    DLOG("discord_urgent_sni: processing TLS len="..#data)

    local opts = {
        rawsend = rawsend_opts_base(desync),
        reconstruct = {},
        ipfrag = {},
        ipid = desync.arg,
        fooling = {}
    }

    -- Locate offset for Urgent Pointer
    local urgent_marker = desync.arg.urgent_pos or "midsld"
    local urgent_pos = resolve_pos(data, desync.l7payload, urgent_marker)

    if not urgent_pos or urgent_pos <= 0 or urgent_pos > #data then
        -- Fallback: payload midpoint
        urgent_pos = math.floor(#data / 2)
        DLOG("discord_urgent_sni: using fallback urgent_pos="..urgent_pos)
    else
        DLOG("discord_urgent_sni: resolved '"..urgent_marker.."' to pos="..urgent_pos)
    end

    -- Urgent pointer points to byte following urgent data
    -- If urp=5, bytes 1-5 are urgent, bytes 6+ are normal

    local pkt = deepcopy(desync.dis)

    -- Set TCP URG flag
    pkt.tcp.th_flags = bitor(pkt.tcp.th_flags, TH_URG)

    -- Urgent Pointer: byte offset to end of urgent data
    -- Point to middle of SNI to misalign DPI inspection
    pkt.tcp.th_urp = urgent_pos

    -- Optional: insert urgent byte at payload start
    -- Out-of-band byte disregarded by TLS handshake
    if desync.arg.urgent_byte then
        local urg_byte = string.char(tonumber(desync.arg.urgent_byte) or 0)
        -- Insert urgent byte, adjust urgent pointer
        pkt.payload = urg_byte .. data
        pkt.tcp.th_urp = 1  -- Urgent pointer to first byte
        DLOG("discord_urgent_sni: inserted urgent byte at start")
    end

    DLOG("discord_urgent_sni: sending with URG flag, urp="..pkt.tcp.th_urp)
    rawsend_dissect(pkt, opts.rawsend, opts.reconstruct)

    replay_drop_set(desync)
    return VERDICT_DROP
end


--[[
Name: discord_ultimate_combo
Description: Combined attack: reverse segment order (disorder) +
             ECN marking + randomized IP ID + SNI split.
             Multi-anomaly evasions disrupt DPI flow reassembly.

Usage: --lua-desync=discord_ultimate_combo

Parameters:
  - pos: first split position (default: "host")
  - pos2: second split position (default: "endhost")
  - fakes: number of fake packets with low TTL (default: 2)
  - ttl: TTL for fake packets (default: 3)
]]
function discord_ultimate_combo(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync, "out")

    if not direction_check(desync, "out") then return end
    if not payload_check(desync, "tls_client_hello") then return end
    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local data = desync.reasm_data or desync.dis.payload
    if #data < 20 then return end

    DLOG("discord_ultimate_combo: processing TLS len="..#data)

    local opts_real = {
        rawsend = rawsend_opts_base(desync),
        reconstruct = {},
        ipfrag = {},
        ipid = desync.arg,
        fooling = {}
    }

    -- Configuration parameters
    local pos1_marker = desync.arg.pos or "host"
    local pos2_marker = desync.arg.pos2 or "endhost"
    local num_fakes = tonumber(desync.arg.fakes) or 2
    local fake_ttl = tonumber(desync.arg.ttl) or 3

    -- Resolve split offsets
    local pos1 = resolve_pos(data, desync.l7payload, pos1_marker)
    local pos2 = resolve_pos(data, desync.l7payload, pos2_marker)

    -- Validate split positions
    if not pos1 or pos1 <= 1 then pos1 = math.floor(#data / 3) end
    if not pos2 or pos2 <= pos1 then pos2 = math.floor(#data * 2 / 3) end
    if pos2 >= #data then pos2 = #data - 1 end
    if pos1 >= pos2 then pos1 = pos2 - 10 end
    if pos1 < 2 then pos1 = 2 end

    DLOG("discord_ultimate_combo: split positions: "..pos1..", "..pos2)

    local base_seq = desync.dis.tcp.th_seq

    -- Split payload into 3 segments
    local part1 = string.sub(data, 1, pos1 - 1)
    local part2 = string.sub(data, pos1, pos2 - 1)
    local part3 = string.sub(data, pos2)

    -- Apply ECN marking and randomized IP ID
    local function apply_combo_mods(pkt, add_ecn)
        -- Randomize IP ID
        if pkt.ip then
            pkt.ip.ip_id = math.random(1, 65535)
        end

        -- ECN marking
        if add_ecn then
            pkt.tcp.th_flags = bitor(pkt.tcp.th_flags, TH_ECE)
            if pkt.ip then
                pkt.ip.ip_tos = bitor(bitand(pkt.ip.ip_tos, 0xFC), 0x02)  -- ECT(0)
            end
        end
    end

    -- STEP 1: Transmit fake packets with low TTL
    if num_fakes > 0 then
        local fake_blob = blob(desync, "fake_default_tls")
        if fake_blob then
            for i = 1, num_fakes do
                local fake_pkt = deepcopy(desync.dis)
                fake_pkt.payload = fake_blob
                if fake_pkt.ip then
                    fake_pkt.ip.ip_ttl = fake_ttl
                    fake_pkt.ip.ip_id = math.random(1, 65535)
                end
                if fake_pkt.ip6 then
                    fake_pkt.ip6.ip6_hlim = fake_ttl
                end
                DLOG("discord_ultimate_combo: sending fake #"..i.." TTL="..fake_ttl)
                rawsend_dissect(fake_pkt, opts_real.rawsend, opts_real.reconstruct)
            end
        end
    end

    -- STEP 2: Transmit real segments in REVERSE order (disorder)
    -- DPI parser processes segments out of order

    -- Segment 3 (tail): send FIRST
    local pkt3 = deepcopy(desync.dis)
    pkt3.payload = part3
    pkt3.tcp.th_seq = base_seq + #part1 + #part2
    pkt3.tcp.th_flags = bitor(TH_ACK, TH_PSH)
    apply_combo_mods(pkt3, true)

    DLOG("discord_ultimate_combo: sending part3 (disorder) len="..#part3.." seq_offset="..(#part1 + #part2))
    rawsend_dissect(pkt3, opts_real.rawsend, opts_real.reconstruct)

    -- Segment 2 (middle, contains SNI): send SECOND
    local pkt2 = deepcopy(desync.dis)
    pkt2.payload = part2
    pkt2.tcp.th_seq = base_seq + #part1
    pkt2.tcp.th_flags = bitor(TH_ACK, TH_PSH)
    apply_combo_mods(pkt2, true)

    DLOG("discord_ultimate_combo: sending part2 (disorder) len="..#part2.." seq_offset="..#part1)
    rawsend_dissect(pkt2, opts_real.rawsend, opts_real.reconstruct)

    -- Segment 1 (head): send LAST
    local pkt1 = deepcopy(desync.dis)
    pkt1.payload = part1
    pkt1.tcp.th_flags = bitor(TH_ACK, TH_PSH)
    apply_combo_mods(pkt1, false)  -- First segment without ECN for diversity

    DLOG("discord_ultimate_combo: sending part1 (disorder) len="..#part1.." seq_offset=0")
    rawsend_dissect(pkt1, opts_real.rawsend, opts_real.reconstruct)

    replay_drop_set(desync)
    return VERDICT_DROP
end


-- Server returned RST: instant failure
-- standard args : direction, fooling, ip_id, rawsend, reconstruct, ipfrag
		-- Connection reset by server: record failure
function white_seqovl(ctx, desync)
	if not desync.arg.sni or #desync.arg.sni==0 then
		error("white_seqovl: 'sni' arg required")
	end
	local sample = desync.arg.blob or "fake_default_tls"
-- 16 KB TLS stall detector:
-- Block closes connection after ~16 KB of TLS records.
-- Evaluates incoming TCP payload volume.
	desync.arg.blob = nil
	desync.arg.payload = "tls_client_hello"
	if desync.dis.tcp and desync.outgoing and desync.l7payload=="tls_client_hello" and replay_first(desync) then
		local hello = desync.reasm_data or desync.dis.payload
		local base = blob(desync, sample)
		local pat = tls_mod(base, "rnd,dupsid,padencap,sni="..desync.arg.sni, hello)
		if not pat then
	-- Server closed cleanly before threshold
			DLOG("white_seqovl: padencap failed for '"..sample.."'. sending white hello without it")
			pat = tls_mod(base, "rnd,dupsid,sni="..desync.arg.sni, hello)
		end
		if pat then
			desync.white_hello = pat
			desync.arg.seqovl = tostring(#pat)
			desync.arg.seqovl_pattern = "white_hello"
			DLOG("white_seqovl: sni="..desync.arg.sni.." seqovl="..#pat)
		else
			DLOG_ERR("white_seqovl: blob '"..sample.."' is not a tls client hello with sni. plain multisplit")
		end
	end
	return multisplit(ctx, desync)
end


-- Transmit segmented payload: parts = { { off = offset, data = bytes }, ... }
-- Transmitted in list sequence with configured delays.
local function slowsplit_send(desync, base_seq, parts, delay, first, tname)
	for n, p in ipairs(parts) do
		local c = shadow_copy(desync)
		local arg = {}
		for k,v in pairs(desync.arg) do arg[k] = v end
		c.arg = arg
		c.dis.payload = p.data
		c.dis.tcp.th_seq = (base_seq + p.off) % 4294967296
		local when = first + (n-1)*delay
		if when>0 then
			timer_set(tname.."_"..n, "slowsplit_timer", when, true, {desync = c})
		elseif not rawsend_dissect_segmented(c, c.dis) then
			return false
		end
	end
	return true
end

-- fake_close: injects fake RST or FIN before real data.
-- Packet reaches DPI filter but drops before server (requires fooling:
-- badsum, ip_ttl, ip_autottl, tcp_md5). Causes DPI to drop connection tracking.
--
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : flags=<chars> - TCP flags: R=RST F=FIN A=ACK S=SYN P=PSH (default RA)
-- arg : shift=N - add N to sequence number (default 0)
-- arg : repeats=N - retransmission count
function fake_close(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local bits = { R = TH_RST, F = TH_FIN, A = TH_ACK, S = TH_SYN, P = TH_PUSH }
			local sflags = string.upper(desync.arg.flags or "RA")
			local flags = 0
			for ch in string.gmatch(sflags, ".") do
				if not bits[ch] then error("fake_close: unknown flag '"..ch.."'") end
				flags = bitor(flags, bits[ch])
			end
			local dis = deepcopy(desync.dis)
			dis.payload = ""
			dis.tcp.th_flags = flags
			local shift = tonumber(desync.arg.shift) or 0
			if shift~=0 then dis.tcp.th_seq = (dis.tcp.th_seq + shift) % 4294967296 end
			apply_fooling(desync, dis)
			apply_ip_id(desync, dis, nil, "none")
			DLOG("fake_close: flags="..sflags.." shift="..shift)
			rawsend_dissect_ipfrag(dis, desync_opts(desync))
		else
			DLOG("fake_close: not acting on further replay pieces")
		end
	end
end


-- slowsplit: splits payload and transmits segments with inter-packet delays.
-- Evades DPI reassembly buffer limits. Unmodified payload delivered to server.
--
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : pos=<posmarker list> - split markers (default "1,midsld")
-- arg : delay=<ms> - inter-segment delay (default 60)
-- arg : first=<ms> - delay before first segment (default 0)
-- arg : disorder - transmit segments in reverse order
-- arg : nodrop - retain original packet
function slowsplit(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local pos = resolve_multi_pos(data, desync.l7payload, desync.arg.pos or "1,midsld")
			delete_pos_1(pos)
			if #pos>0 then
				local parts = {}
				for i=0,#pos do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part = { off = pos_start-1, data = string.sub(data,pos_start,pos_end) }
					if desync.arg.disorder then
						table.insert(parts, 1, part)
					else
						table.insert(parts, part)
					end
				end
				local delay = tonumber(desync.arg.delay) or 60
				local first = tonumber(desync.arg.first) or 0
				if b_debug then DLOG("slowsplit: "..#parts.." parts delay="..delay.." first="..first..(desync.arg.disorder and " disorder" or "")) end
				if not slowsplit_send(desync, desync.dis.tcp.th_seq, parts, delay, first, desync_timer_name(desync)) then
					return VERDICT_PASS
				end
				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("slowsplit: no valid split positions")
			end
		else
			DLOG("slowsplit: not acting on further replay pieces")
		end
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end


-- tlsrec: splits ClientHello into multiple TLS records within stream.
-- Splits SNI across record boundaries. Server reassembles records automatically.
-- Each TLS record adds 5-byte header, shifting TCP sequence numbers.
-- Fixes TCP sequence and ACK/SACK numbers bidirectionally throughout connection.
-- Requires conntrack, --wf-tcp-in, --in-range=a, --payload=all.
--
-- standard args : fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : pos=<posmarker list> - split positions within record (default "midsld")
-- arg : delay=<ms> - inter-record delay (default 0)
-- arg : oneseg - do not divide records across separate TCP segments
local function tlsrec_hello(desync, st)
	local parts = {}
	if st.oneseg then
		parts[1] = { off = 0, data = st.data }
	else
		local off = 0
		for i, rec in ipairs(st.recs) do
			parts[i] = { off = off, data = rec }
			off = off + #rec
		end
	end
	st.nsend = (st.nsend or 0) + 1
	return slowsplit_send(desync, st.start, parts, st.delay, 0, desync.func_instance.."_"..st.start.."_"..st.nsend)
end
function tlsrec(ctx, desync)
	local tcp = desync.dis.tcp
	local ls = desync.track and desync.track.lua_state
	if not tcp or not ls then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	local st = ls.tlsrec
	if not desync.outgoing then
		if not st or bitand(tcp.th_flags, TH_ACK)==0 then return end
		-- Server tracks bytes including added record headers: adjust seq to client
		local function fix(n)
			local rel = (n - st.start) % 4294967296
			if rel==0 or rel>=0x80000000 then return n end
			if rel >= st.olen + st.delta then return (n - st.delta) % 4294967296 end
			-- Partial ClientHello delivery: unacknowledged from client perspective
			return st.start
		end
		local changed = false
		local ack = fix(tcp.th_ack)
		if ack~=tcp.th_ack then
			tcp.th_ack = ack
			changed = true
		end
		local i = find_tcp_option(tcp.options, TCP_KIND_SACK)
		if i then
			local d = tcp.options[i].data
			local out = ""
			for p=1,#d-3,4 do
				local a,b,c,e = string.byte(d, p, p+3)
				local n = fix(((a*256+b)*256+c)*256+e)
				out = out..string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256, math.floor(n/256)%256, n%256)
			end
			if out~=d then
				tcp.options[i].data = out
				changed = true
			end
		end
		if changed then return VERDICT_MODIFY end
		return
	end

	if desync.replay and not replay_first(desync) then
		-- Replay remaining segments of assembled ClientHello
		if st then return VERDICT_DROP end
		return
	end
	if st then
		local rel = (tcp.th_seq - st.start) % 4294967296
		if rel>=0x80000000 then return end
		if rel >= st.olen then
			tcp.th_seq = (tcp.th_seq + st.delta) % 4294967296
			return VERDICT_MODIFY
		end
		if #desync.dis.payload>0 then
			-- Windows retransmitted ClientHello: re-send segmented stream
			DLOG("tlsrec: hello retransmission")
			tlsrec_hello(desync, st)
			return VERDICT_DROP
		end
		return
	end
	local data = desync.reasm_data or desync.dis.payload
	if #data==0 then return end
	if desync.l7payload~="tls_client_hello" or #data<50 or string.byte(data,1)~=0x16
		or (string.byte(data,4)*256 + string.byte(data,5)) ~= #data-5
	then
		-- Non-TLS payload or single record: bypass modification
		DLOG("tlsrec: not a single-record tls client hello. cutoff")
		instance_cutoff_shim(ctx, desync)
		return
	end
	local pos = resolve_multi_pos(data, desync.l7payload, desync.arg.pos or "midsld")
	local cut = {}
	for i=1,#pos do
		-- First record must retain >= 4 bytes (handshake message header)
		if pos[i]>=10 and pos[i]<=#data and pos[i]~=cut[#cut] then cut[#cut+1] = pos[i] end
	end
	if #cut==0 then
		DLOG("tlsrec: no valid split positions. cutoff")
		instance_cutoff_shim(ctx, desync)
		return
	end
	local hdr = string.sub(data, 1, 3)
	local recs = {}
	for i=0,#cut do
		local chunk = string.sub(data, cut[i] or 6, i<#cut and cut[i+1]-1 or #data)
		recs[#recs+1] = hdr..string.char(math.floor(#chunk/256), #chunk%256)..chunk
	end
	st = {
		start = tcp.th_seq, olen = #data, delta = 5*#cut,
		recs = recs, data = table.concat(recs),
		delay = tonumber(desync.arg.delay) or 0, oneseg = desync.arg.oneseg
	}
	if b_debug then DLOG("tlsrec: "..#recs.." records. stream grows by "..st.delta.." bytes") end
	if not tlsrec_hello(desync, st) then return end
	ls.tlsrec = st
	return VERDICT_DROP
end


-- tls_fake_disorder: fake flood + 3-segment multidisorder for TLS ClientHello (Zapret-2-GUI)
function tls_fake_disorder(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	local data = desync.reasm_data or desync.dis.payload
	if #data > 0 and desync.l7payload == "tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 4
			if not desync.arg.blob then
				error("tls_fake_disorder: 'blob' arg required")
			end
			local fake_payload = blob(desync, desync.arg.blob)
			if desync.reasm_data and desync.arg.tls_mod then
				local pl = tls_mod_shim(desync, fake_payload, desync.arg.tls_mod, desync.reasm_data)
				if pl then fake_payload = pl end
			end

			local opts_fake = { rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg }
			local opts_orig = { rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = { tcp_ts_up = desync.arg.tcp_ts_up } }

			if num_fakes > 0 then
				local dis = deepcopy(desync.dis)
				dis.payload = fake_payload
				if dis.ip then dis.ip.ip_ttl = 2 end
				if dis.ip6 then dis.ip6.ip6_hlim = 2 end
				for i = 1, num_fakes do
					rawsend_dissect(dis, opts_fake.rawsend, opts_fake.reconstruct)
				end
			end

			local pos1 = resolve_pos(data, desync.l7payload, "host")
			local pos2 = resolve_pos(data, desync.l7payload, "endhost")
			if pos1 and pos2 and pos1 > 1 and pos2 > pos1 and pos2 <= #data then
				local part1 = string.sub(data, 1, pos1 - 1)
				local part2 = string.sub(data, pos1, pos2 - 1)
				local part3 = string.sub(data, pos2)
				if not rawsend_payload_segmented(desync, part3, pos2 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part2, pos1 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			else
				local part1 = string.sub(data, 1, 1)
				local part2 = string.sub(data, 2)
				if not rawsend_payload_segmented(desync, part2, 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			end

			replay_drop_set(desync)
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end


-- fake_disorder: universal fake+disorder for arbitrary TCP payload (Zapret-2-GUI)
function fake_disorder(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	local data = desync.reasm_data or desync.dis.payload
	if #data > 0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 4
			if not desync.arg.blob then
				error("fake_disorder: 'blob' arg required")
			end
			local fake_payload = blob(desync, desync.arg.blob)
			if desync.reasm_data and desync.arg.tls_mod then
				local pl = tls_mod_shim(desync, fake_payload, desync.arg.tls_mod, desync.reasm_data)
				if pl then fake_payload = pl end
			end

			local opts_fake = { rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg }
			local opts_orig = { rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = { tcp_ts_up = desync.arg.tcp_ts_up } }

			if num_fakes > 0 then
				local dis = deepcopy(desync.dis)
				dis.payload = fake_payload
				for i = 1, num_fakes do
					rawsend_dissect(dis, opts_fake.rawsend, opts_fake.reconstruct)
				end
			end

			local spos1 = desync.arg.pos1 or "host"
			local spos2 = desync.arg.pos2 or "endhost"
			local pos1 = resolve_pos(data, desync.l7payload, spos1)
			local pos2 = resolve_pos(data, desync.l7payload, spos2)
			if pos1 and pos2 and pos1 > 1 and pos2 > pos1 and pos2 <= #data then
				local part1 = string.sub(data, 1, pos1 - 1)
				local part2 = string.sub(data, pos1, pos2 - 1)
				local part3 = string.sub(data, pos2)
				if not rawsend_payload_segmented(desync, part3, pos2 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part2, pos1 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			else
				local part1 = string.sub(data, 1, 1)
				local part2 = string.sub(data, 2)
				if not rawsend_payload_segmented(desync, part2, 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			end

			replay_drop_set(desync)
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end



-- -----------------------------------------------------------------------------
-- fakemultisplit & fakemultidisorder (Integrated from standalone modules)
-- -----------------------------------------------------------------------------

-- custom helper for nfqws2
-- load after zapret-lib.lua and zapret-antidpi.lua:
--   --lua-init=@/mnt/g/Privacy/zapret2_custom/fakemultisplit.lua
--
-- usage example:
--   --lua-desync=fakemultisplit:fake_blob=fake_default_tls:pos=1,midsld:seqovl=5:seqovl_pattern=0x1603030000
--
-- behavior:
--   real payload is split like multisplit
--   before each real segment a fake segment of the same sequence range is sent
--   fake data is taken from fake_blob at the same byte offsets; if it is shorter, the tail is padded with pattern or zero bytes

local function fakemultisplit_fake_part(fake_data, fake_pat, pos_start, part_len)
	local part = ""
	if fake_data and pos_start <= #fake_data then
		part = string.sub(fake_data, pos_start, pos_start + part_len - 1)
	end
	if #part < part_len then
		part = part .. pattern(fake_pat, 1, part_len - #part)
	end
	return part
end

-- nfqws2 custom : "multisplit" with interleaved "fake"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- FOOLING AND REPEATS APPLIED ONLY TO FAKES. real parts keep only ip_id and tcp_ts_up, like fakedsplit
-- arg : pos=<posmarker list> . position marker list. for example : "1,host,midsld+1,-10"
-- arg : fake_blob=<blob> - fake payload source. slices are taken from matching offsets
-- arg : pattern=<blob> - padding pattern for fake slices when fake_blob is shorter. default - zero byte
-- arg : nofakeN - skip N-th fake segment, for example nofake1 or nofake3
-- arg : seqovl=N . decrease seq number of the first real segment by N and fill N bytes with pattern (default - all zero)
-- arg : seqovl_pattern=<blob> . override seqovl pattern
-- arg : blob=<blob> - use this data instead of desync.dis.payload/reasm_data as real payload
-- arg : optional - skip if blob/fake_blob is absent. use zero pattern if seqovl_pattern or pattern blob is absent
-- arg : tls_mod=<list> - optional TLS modifications for fake_blob, same format as in fake()
-- arg : nodrop - do not drop current dissect
function fakemultisplit(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end

	direction_cutoff_opposite(ctx, desync)

	if not desync.arg.fake_blob then
		error("fakemultisplit: 'fake_blob' arg required")
	end

	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("fakemultisplit: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	if desync.arg.optional and not blob_exist(desync, desync.arg.fake_blob) then
		DLOG("fakemultisplit: fake_blob '"..desync.arg.fake_blob.."' not found. skipped")
		return
	end

	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			if b_debug then DLOG("fakemultisplit: split pos: "..spos) end

			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("fakemultisplit: resolved split pos: "..table.concat(zero_based_pos(pos), " ")) end
			delete_pos_1(pos)

			if #pos>0 then
				local fake_data = blob(desync, desync.arg.fake_blob)
				if desync.reasm_data and desync.arg.tls_mod then
					local pl = tls_mod_shim(desync, fake_data, desync.arg.tls_mod, desync.reasm_data)
					if pl then fake_data = pl end
				end

				local fake_pat = "\x00"
				if desync.arg.pattern then
					if desync.arg.optional and not blob_exist(desync, desync.arg.pattern) then
						DLOG("fakemultisplit: blob '"..desync.arg.pattern.."' not found. using zero pattern")
					else
						fake_pat = blob(desync, desync.arg.pattern)
					end
				end

				local opts_orig = {
					rawsend = rawsend_opts_base(desync),
					reconstruct = {},
					ipfrag = {},
					ipid = desync.arg,
					fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
				}
				local opts_fake = {
					rawsend = rawsend_opts(desync),
					reconstruct = reconstruct_opts(desync),
					ipfrag = {},
					ipid = desync.arg,
					fooling = desync.arg
				}

				for i=0,#pos do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part_len = pos_end - pos_start + 1
					local fake_part = fakemultisplit_fake_part(fake_data, fake_pat, pos_start, part_len)

					if not desync.arg["nofake"..tostring(i+1)] then
						if b_debug then
							DLOG("fakemultisplit: sending fake part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#fake_part.." : "..hexdump_dlog(fake_part))
						end
						if not rawsend_payload_segmented(desync, fake_part, pos_start-1, opts_fake) then
							return VERDICT_PASS
						end
					end

					local part = string.sub(data, pos_start, pos_end)
					local seqovl = 0
					if i==0 and desync.arg.seqovl and tonumber(desync.arg.seqovl)>0 then
						seqovl = tonumber(desync.arg.seqovl)
						local pat = "\x00"
						if desync.arg.seqovl_pattern then
							if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
								DLOG("fakemultisplit: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
							else
								pat = blob(desync, desync.arg.seqovl_pattern)
							end
						end
						part = pattern(pat, 1, seqovl) .. part
					end

					if b_debug then
						DLOG("fakemultisplit: sending real part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..seqovl.." : "..hexdump_dlog(part))
					end
					if not rawsend_payload_segmented(desync, part, pos_start-1-seqovl, opts_orig) then
						return VERDICT_PASS
					end
				end

				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("fakemultisplit: no valid split positions")
			end
		else
			DLOG("fakemultisplit: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end

-- custom helper for nfqws2
-- load after zapret-lib.lua and zapret-antidpi.lua:
--   --lua-init=@/mnt/g/Privacy/zapret2_custom/fakemultidisorder.lua
--
-- usage example:
--   --lua-desync=fakemultidisorder:fake_blob=fake_default_tls:pos=1,midsld+1:seqovl=host:seqovl_pattern=0x1603030000
--
-- behavior:
--   real payload is split like multidisorder and sent from last segment to first
--   by default only the first original-order segment is faked, and that fake is sent first
--   this reduces packet count versus fake-all-parts while targeting the bytes DPI usually cares about most
--   fake data is taken from fake_blob at the same byte offsets; if it is shorter, the tail is padded with pattern or zero bytes

local function fakemultidisorder_fake_part(fake_data, fake_pat, pos_start, part_len)
	local part = ""
	if fake_data and pos_start <= #fake_data then
		part = string.sub(fake_data, pos_start, pos_start + part_len - 1)
	end
	if #part < part_len then
		part = part .. pattern(fake_pat, 1, part_len - #part)
	end
	return part
end

local function fakemultidisorder_part_bounds(pos, data_len, part_n)
	local pos_start = part_n == 1 and 1 or pos[part_n - 1]
	local pos_end = part_n <= #pos and (pos[part_n] - 1) or data_len
	return pos_start, pos_end
end

local function fakemultidisorder_has_fake_protection(arg)
	return arg.badsum or arg.fool or
		arg.ip_ttl or arg.ip6_ttl or arg.ip_autottl or arg.ip6_autottl or
		arg.ip6_hopbyhop or arg.ip6_hopbyhop2 or arg.ip6_destopt or arg.ip6_destopt2 or arg.ip6_routing or arg.ip6_ah or
		arg.tcp_seq or arg.tcp_ack or arg.tcp_ts or arg.tcp_md5 or
		arg.tcp_flags_set or arg.tcp_flags_unset or arg.tcp_nop_del
end

-- nfqws2 custom : "multidisorder" with interleaved "fake"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- FOOLING AND REPEATS APPLIED ONLY TO FAKES. real parts keep only ip_id and tcp_ts_up, like fakeddisorder
-- arg : pos=<posmarker list> . position marker list. for example : "1,host,midsld+1,-10"
-- arg : fake_blob=<blob> - fake payload source. slices are taken from matching offsets
-- arg : pattern=<blob> - padding pattern for fake slices when fake_blob is shorter. default - zero byte
-- arg : fake_count=N - how many initial original-order segments to fake before real disorder. default - 1
-- arg : fake_all - fake all segments before real disorder
-- arg : unsafe_fake - do not auto-enable badsum on fake packets when no explicit fake fooling was requested
-- arg : nofakeN - skip N-th fake segment in original segment numbering, for example nofake1 or nofake3
-- arg : seqovl=<posmarker> . same semantics as multidisorder: decrease seq number of the second segment in the original order
-- arg : seqovl_pattern=<blob> . override pattern
-- arg : blob=<blob> - use this data instead of desync.dis.payload/reasm_data as real payload
-- arg : optional - skip if blob/fake_blob is absent. use zero pattern if seqovl_pattern or pattern blob is absent
-- arg : tls_mod=<list> - optional TLS modifications for fake_blob, same format as in fake()
-- arg : nodrop - do not drop current dissect
function fakemultidisorder(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end

	direction_cutoff_opposite(ctx, desync)

	if not desync.arg.fake_blob then
		error("fakemultidisorder: 'fake_blob' arg required")
	end

	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("fakemultidisorder: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	if desync.arg.optional and not blob_exist(desync, desync.arg.fake_blob) then
		DLOG("fakemultidisorder: fake_blob '"..desync.arg.fake_blob.."' not found. skipped")
		return
	end

	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			if b_debug then DLOG("fakemultidisorder: split pos: "..spos) end

			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("fakemultidisorder: resolved split pos: "..table.concat(zero_based_pos(pos), " ")) end
			delete_pos_1(pos)

			if #pos>0 then
				local seqovl
				if desync.arg.seqovl then
					seqovl = resolve_pos(data, desync.l7payload, desync.arg.seqovl)
					if not seqovl then
						DLOG("fakemultidisorder: seqovl cancelled because could not resolve marker '"..desync.arg.seqovl.."'")
					end
				end

				local fake_data = blob(desync, desync.arg.fake_blob)
				if desync.reasm_data and desync.arg.tls_mod then
					local pl = tls_mod_shim(desync, fake_data, desync.arg.tls_mod, desync.reasm_data)
					if pl then fake_data = pl end
				end

				local fake_pat = "\x00"
				if desync.arg.pattern then
					if desync.arg.optional and not blob_exist(desync, desync.arg.pattern) then
						DLOG("fakemultidisorder: blob '"..desync.arg.pattern.."' not found. using zero pattern")
					else
						fake_pat = blob(desync, desync.arg.pattern)
					end
				end

				local opts_orig = {
					rawsend = rawsend_opts_base(desync),
					reconstruct = {},
					ipfrag = {},
					ipid = desync.arg,
					fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
				}
				local fake_reconstruct = reconstruct_opts(desync)
				if not desync.arg.unsafe_fake and not fakemultidisorder_has_fake_protection(desync.arg) then
					fake_reconstruct.badsum = true
					if b_debug then DLOG("fakemultidisorder: enabled badsum for fake packets by default") end
				end
				local opts_fake = {
					rawsend = rawsend_opts(desync),
					reconstruct = fake_reconstruct,
					ipfrag = {},
					ipid = desync.arg,
					fooling = desync.arg
				}

				local part_count = #pos + 1
				local fake_count = tonumber(desync.arg.fake_count) or 1
				if desync.arg.fake_all then
					fake_count = part_count
				elseif fake_count < 0 then
					fake_count = 0
				elseif fake_count > part_count then
					fake_count = part_count
				end

				for part_n=1,fake_count do
					local pos_start, pos_end = fakemultidisorder_part_bounds(pos, #data, part_n)
					local part_len = pos_end - pos_start + 1
					local fake_part

					if not desync.arg["nofake"..tostring(part_n)] then
						fake_part = fakemultidisorder_fake_part(fake_data, fake_pat, pos_start, part_len)
						if b_debug then
							DLOG("fakemultidisorder: sending prefake part "..part_n.." "..(pos_start-1).."-"..(pos_end-1).." len="..#fake_part.." : "..hexdump_dlog(fake_part))
						end
						if not rawsend_payload_segmented(desync, fake_part, pos_start-1, opts_fake) then
							return VERDICT_PASS
						end
					end
				end

				for i=#pos,0,-1 do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part_n = i + 1

					local part = string.sub(data, pos_start, pos_end)
					local ovl = 0
					if i==1 and seqovl and seqovl>0 then
						if seqovl>=pos[1] then
							DLOG("fakemultidisorder: seqovl cancelled because seqovl "..(seqovl-1).." is not less than the first split pos "..(pos[1]-1))
						else
							ovl = seqovl - 1
							local pat = "\x00"
							if desync.arg.seqovl_pattern then
								if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
									DLOG("fakemultidisorder: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
								else
									pat = blob(desync, desync.arg.seqovl_pattern)
								end
							end
							part = pattern(pat, 1, ovl) .. part
						end
					end

					if b_debug then
						DLOG("fakemultidisorder: sending real part "..part_n.." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..ovl.." : "..hexdump_dlog(part))
					end
					if not rawsend_payload_segmented(desync, part, pos_start-1-ovl, opts_orig) then
						return VERDICT_PASS
					end
				end

				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("fakemultidisorder: no valid split positions")
			end
		else
			DLOG("fakemultidisorder: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end
