// Per-player field of view: each local client's own cg_fov for its pane.
// Part of splitscreen.cpp, included in order inside namespace splitscreen::{anon}.

		// ============ Per-player field of view (Splitscreen4P 2.8.0) ============
		// cg_fov is one dvar and every pane's view is built from its current value
		// when that client's frame is drawn, so with one slider all panes share
		// player 1's FOV. SCR_UpdateFrame draws the local clients one after another
		// on the game thread: two copies of the client loop (the ones whose bounds
		// cg_frame_imms widens) and a single-client path that calls the same
		// per-client draw. A mid-function hook at the top of each client's turn,
		// where the register that carries the client is still live, writes that
		// player's FOV into cg_fov's current value - a direct write, like
		// set_splitscreen_player_count (never Dvar_SetFloat: Arxan caller guard).
		// The game's own value goes back for player 1 and after the loop (the frame
		// counter the loops' common exit calls, detoured), so the Options slider, the
		// config write and whatever else reads cg_fov between frames see player 1's
		// value. The game copies cg_fov_default into cg_fov only on events (the copy
		// at 0x00879F00 has no direct caller, CG_SetFov one), never per frame, so the
		// per-client value survives until the draw.
		//
		// Players 2-4 keep their values in the string dvars splitscreen_fov_2..4,
		// which the Controls options list (zz_splitscreen Lua) writes with `set` (an
		// unknown name becomes a string dvar). The component finds them in the dvar
		// pool - one static array of fixed-size records; cg_fov and cg_fov_default,
		// both reached through their pointer slots and checked by name, fix where the
		// pool is and that the stride holds - reads their text, and marks them archived
		// (dvar_archive, which the engine's own saved dvars carry) so config.cfg keeps
		// them across starts. Empty, 0 or out of cg_fov's domain: player 1's value.

		constexpr size_t dvar_current_float = dvar_current_offset;   // float at +0x28
		constexpr size_t dvar_domain_min = 0x88;                     // float min, float max
		constexpr size_t dvar_domain_max = 0x8C;
		constexpr size_t dvar_pool_records_max = 32768;

		bool player_fov_installed = false;
		utils::hook::detour frame_end_hook;
		volatile float* cg_fov_current = nullptr;
		float cg_fov_min = 1.0f;
		float cg_fov_max = 160.0f;
		uint8_t* dvar_pool_start = nullptr;
		std::atomic<float> guest_fov[4]{};          // index = local client; 0 = player 1's value
		uint8_t* guest_fov_dvar[4]{};               // the splitscreen_fov_<n> records, once found
		const char* const guest_fov_names[4] = {nullptr, "splitscreen_fov_2", "splitscreen_fov_3", "splitscreen_fov_4"};

		// The record's name, when the record reads like a registered dvar: a readable
		// pointer at +8 to a short printable string. Null for an unused or foreign slot.
		const char* dvar_record_name(const uint8_t* record)
		{
			if (!readable(record, dvar_record_size))
			{
				return nullptr;
			}
			const char* name = nullptr;
			std::memcpy(&name, record + dvar_name_offset, sizeof(name));
			if (!name || !readable(name, dvar_name_max))
			{
				return nullptr;
			}
			for (size_t i = 0; i < dvar_name_max; ++i)
			{
				const auto c = static_cast<unsigned char>(name[i]);
				if (c == 0)
				{
					return i ? name : nullptr;
				}
				if (c < 0x21 || c > 0x7E)
				{
					return nullptr;
				}
			}
			return nullptr;
		}

		uint32_t dvar_record_type(const uint8_t* record)
		{
			uint32_t type = 0;
			std::memcpy(&type, record + dvar_type_offset, sizeof(type));
			return type;
		}

		// The record a pointer slot holds, when it is the named dvar of that type.
		uint8_t* dvar_from_slot(const uint32_t slot_rva, const char* name, const uint32_t type)
		{
			const auto* slot = reinterpret_cast<const void*>(base() + slot_rva);
			if (!readable(slot, sizeof(uint8_t*)))
			{
				return nullptr;
			}
			uint8_t* record = nullptr;
			std::memcpy(&record, slot, sizeof(record));
			const auto* found = dvar_record_name(record);
			if (!found || std::strcmp(found, name) != 0 || dvar_record_type(record) != type)
			{
				return nullptr;
			}
			return record;
		}

		// A page the game writes itself (the dvar pool is .data).
		bool writable(const void* p, const size_t size)
		{
			MEMORY_BASIC_INFORMATION mbi{};
			if (!readable(p, size) || !VirtualQuery(p, &mbi, sizeof(mbi)))
			{
				return false;
			}
			const auto protect = mbi.Protect & 0xFF;
			return protect == PAGE_READWRITE || protect == PAGE_WRITECOPY
				|| protect == PAGE_EXECUTE_READWRITE || protect == PAGE_EXECUTE_WRITECOPY;
		}

		// The pool record of the named dvar, or null: walks the pool from its first
		// record. The `set`-created dvars sit behind the engine's own.
		uint8_t* find_pool_dvar(const char* name)
		{
			if (!dvar_pool_start)
			{
				return nullptr;
			}
			auto* record = dvar_pool_start;
			for (size_t i = 0; i < dvar_pool_records_max; ++i, record += dvar_record_size)
			{
				const auto* found = dvar_record_name(record);
				if (!found)
				{
					return nullptr;   // the first unused record ends the pool
				}
				if (std::strcmp(found, name) == 0)
				{
					return record;
				}
			}
			return nullptr;
		}

		// ---- The write (game thread, from the frame-loop hooks) ----
		// The game's own value is remembered on the first write of a frame and put
		// back on restore, unless the game changed cg_fov in between (then its new
		// value stays: a script's or the slider's write wins over our copy).
		float fov_stock = 0.0f;
		float fov_written = 0.0f;
		bool fov_overridden = false;

		void fov_set(const float value)
		{
			const float now = *cg_fov_current;
			if (!fov_overridden || now != fov_written)
			{
				fov_stock = now;
			}
			fov_overridden = true;
			*cg_fov_current = value;
			fov_written = value;
		}

		void fov_restore()
		{
			if (!fov_overridden)
			{
				return;
			}
			if (*cg_fov_current == fov_written)
			{
				*cg_fov_current = fov_stock;
			}
			fov_overridden = false;
		}

		void apply_player_fov(const int lc)
		{
			if (!cg_fov_current)
			{
				return;
			}
			const float value = lc >= 1 && lc < 4 ? guest_fov[lc].load(std::memory_order_relaxed) : 0.0f;
			if (value > 0.0f)
			{
				fov_set(value);
			}
			else
			{
				fov_restore();
			}
		}

		void frame_fov_loop_stub(midhook::context& ctx)   // ebx = local client
		{
			apply_player_fov(static_cast<int32_t>(ctx.rbx));
		}

		void frame_fov_single_stub(midhook::context& ctx)   // r15d = local client
		{
			apply_player_fov(static_cast<int32_t>(ctx.r15));
		}

		void frame_end_stub()
		{
			fov_restore();
			frame_end_hook.invoke<void>();
		}

		// ---- The values (async pipeline, poll_player_fov) ----
		// "95", "95.0", " 95" -> 95; anything else 0. No CRT parsing: the text is the
		// game's and short.
		float parse_fov_text(const char* text)
		{
			if (!text || !readable(text, 16))
			{
				return 0.0f;
			}
			float value = 0.0f;
			float scale = 0.0f;
			size_t digits = 0;
			for (size_t i = 0; i < 16 && text[i]; ++i)
			{
				const auto c = text[i];
				if (c >= '0' && c <= '9')
				{
					++digits;
					if (scale == 0.0f)
					{
						value = value * 10.0f + static_cast<float>(c - '0');
					}
					else
					{
						value += static_cast<float>(c - '0') * scale;
						scale /= 10.0f;
					}
				}
				else if (c == '.' && scale == 0.0f)
				{
					scale = 0.1f;
				}
				else if (c == ' ' && digits == 0)
				{
					continue;
				}
				else
				{
					break;
				}
			}
			return digits ? value : 0.0f;
		}

		void poll_player_fov()
		{
			if (!player_fov_installed)
			{
				return;
			}
			for (int lc = 1; lc < 4; ++lc)
			{
				auto*& record = guest_fov_dvar[lc];
				if (!record)
				{
					record = find_pool_dvar(guest_fov_names[lc]);
					if (!record)
					{
						continue;
					}
					// Saved like the engine's own settings (config.cfg `set` lines, run
					// at the next start).
					uint32_t flags = 0;
					std::memcpy(&flags, record + dvar_flags_offset, sizeof(flags));
					if (!(flags & dvar_archive))
					{
						flags |= dvar_archive;
						write_bytes(record + dvar_flags_offset, &flags, sizeof(flags));
					}
					note("player fov: %s found, record 0x%zX", guest_fov_names[lc],
					     static_cast<size_t>(record - reinterpret_cast<uint8_t*>(base())));
				}
				const char* text = nullptr;
				std::memcpy(&text, record + dvar_current_offset, sizeof(text));
				float value = parse_fov_text(text);
				if (value < cg_fov_min || value > cg_fov_max)
				{
					value = 0.0f;   // player 1's
				}
				guest_fov[lc].store(value, std::memory_order_relaxed);
			}
		}

		// All or nothing: the three sites and the frame-end detour, only once cg_fov
		// and cg_fov_default are where the build says, by name, and the pool stride
		// holds between them.
		void install_player_fov()
		{
			if (player_fov_installed)
			{
				return;
			}
			auto* fov = dvar_from_slot(cg_fov_dvar_rva, "cg_fov", dvar_type_float);
			auto* fov_default = dvar_from_slot(cg_fov_default_dvar_rva, "cg_fov_default", dvar_type_float);
			if (!fov || !fov_default)
			{
				note("player fov: cg_fov / cg_fov_default not where expected - off");
				return;
			}
			const auto distance = static_cast<size_t>(fov > fov_default ? fov - fov_default : fov_default - fov);
			if (distance % dvar_record_size != 0 || !writable(fov + dvar_current_float, sizeof(float)))
			{
				note("player fov: dvar pool stride does not hold - off");
				return;
			}
			if (!call_site_targets(frame_end_call_rva, frame_end_rva)
				|| !engine_bytes_match(frame_end_rva, frame_end_prologue))
			{
				note("player fov: frame end differs - off");
				return;
			}

			// The pool's first record: back from cg_fov while the records read as dvars.
			auto* first = fov;
			for (size_t i = 0; i < dvar_pool_records_max && dvar_record_name(first - dvar_record_size); ++i)
			{
				first -= dvar_record_size;
			}

			uint8_t patch_a[32];
			uint8_t patch_b[32];
			uint8_t patch_s[32];
			const auto b = base();
			if (!midhook::prepare(b + frame_fov_loop_a_rva, frame_fov_loop_a_expected,
			                      sizeof(frame_fov_loop_a_expected), &frame_fov_loop_stub,
			                      &allocate_near_module, patch_a)
				|| !midhook::prepare(b + frame_fov_loop_b_rva, frame_fov_loop_b_expected,
				                     sizeof(frame_fov_loop_b_expected), &frame_fov_loop_stub,
				                     &allocate_near_module, patch_b)
				|| !midhook::prepare(b + frame_fov_single_rva, frame_fov_single_expected,
				                     sizeof(frame_fov_single_expected), &frame_fov_single_stub,
				                     &allocate_near_module, patch_s))
			{
				note("player fov: a frame-loop site differs - off");
				return;
			}
			if (!hook_if_stock(frame_end_hook, frame_end_rva, frame_end_prologue, frame_end_stub))
			{
				return;
			}

			cg_fov_current = reinterpret_cast<volatile float*>(fov + dvar_current_float);
			std::memcpy(&cg_fov_min, fov + dvar_domain_min, sizeof(cg_fov_min));
			std::memcpy(&cg_fov_max, fov + dvar_domain_max, sizeof(cg_fov_max));
			if (!(cg_fov_min > 0.0f && cg_fov_max > cg_fov_min))
			{
				cg_fov_min = 1.0f;
				cg_fov_max = 160.0f;
			}
			dvar_pool_start = first;
			write_bytes(reinterpret_cast<void*>(b + frame_fov_loop_a_rva), patch_a, sizeof(frame_fov_loop_a_expected));
			write_bytes(reinterpret_cast<void*>(b + frame_fov_loop_b_rva), patch_b, sizeof(frame_fov_loop_b_expected));
			write_bytes(reinterpret_cast<void*>(b + frame_fov_single_rva), patch_s, sizeof(frame_fov_single_expected));
			FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<void*>(b + frame_fov_loop_a_rva), 0x100);
			FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<void*>(b + frame_fov_single_rva), 0x10);
			player_fov_installed = true;
			note("player fov: installed (pool from 0x%zX, cg_fov domain %g..%g)",
			     static_cast<size_t>(first - reinterpret_cast<uint8_t*>(b)), static_cast<double>(cg_fov_min),
			     static_cast<double>(cg_fov_max));
		}
