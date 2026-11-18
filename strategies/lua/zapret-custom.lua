-- zapret-custom.lua
-- Custom desync functions from Zapret-2-GUI.
-- Load: --lua-init=@lua/zapret-lib.lua --lua-init=@lua/zapret-antidpi.lua --lua-init=@lua/zapret-custom.lua

-- tls_fake_disorder: fake flood + 3-segment multidisorder for TLS ClientHello
--   fakes=N        - number of fake packets (default 4)
--   blob=<name>    - fake payload blob
--   tls_mod=<opts> - optional TLS modifications on fake payload
--   nodrop         - do not drop original packet
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

-- fake_disorder: universal fake+disorder for arbitrary TCP payload
--   fakes=N        - number of fake packets (default 4)
--   blob=<name>    - fake payload blob
--   pos1=<marker>  - first position marker (default "host")
--   pos2=<marker>  - second position marker (default "endhost")
--   tls_mod=<opts> - optional TLS modifications on fake payload
--   nodrop         - do not drop original packet
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

DLOG("zapret-custom.lua loaded: tls_fake_disorder, fake_disorder")
