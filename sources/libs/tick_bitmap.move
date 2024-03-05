module flowx_clmm::tick_bitmap {
    use sui::table::{Self, Table};

    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::caster;
    use flowx_clmm::bit_math;
    use flowx_clmm::constants;

    friend flowx_clmm::pool;

    const E_TICK_MISALIGNED: u64 = 0;

    fun position(tick: I32): (I32, u8) {
        let word_pos = i32::shr(tick, 8);
        let bit_pos = caster::cast_to_u8(i32::mod(tick, i32::from(256)));
        (word_pos, bit_pos)
    }

    fun try_get_tick_word(
        self: &Table<I32, u256>,
        word_pos: I32
    ): u256 {
        if (!table::contains(self, word_pos)) {
            0
        } else {
            *table::borrow(self, word_pos)
        }
    }

    fun try_borrow_mut_tick_word(
        self: &mut Table<I32, u256>,
        word_pos: I32
    ): &mut u256 {
        if (!table::contains(self, word_pos)) {
            table::add(self, word_pos, 0);
        };
        table::borrow_mut(self, word_pos)
    }

    public(friend) fun flip_tick(
        self: &mut Table<I32, u256>,
        tick: I32,
        tick_spacing: u32
    ) {
        assert!(i32::abs_u32(tick) % tick_spacing == 0, E_TICK_MISALIGNED);

        let (word_pos, bit_pos) = position(i32::div(tick, i32::from(tick_spacing)));
        let mask = 1u256 << bit_pos;
        let word = try_borrow_mut_tick_word(self, word_pos);
        *word = *word ^ mask;
    }

    public fun next_initialized_tick_within_one_word(
        self: &Table<I32, u256>,
        tick: I32,
        tick_spacing: u32,
        lte: bool
    ): (I32, bool) {
        let tick_spacing_i32 = i32::from(tick_spacing);
        let compressed = i32::div(tick, tick_spacing_i32);
        if (i32::is_neg(tick) && i32::abs_u32(tick) % tick_spacing != 0) {
            compressed = i32::sub(compressed, i32::from(1));
        };

        let (next, initialized) = if (lte) {
            let (word_pos, bit_pos) = position(compressed);
            let mask = (1u256 << bit_pos) - 1 + (1u256 << bit_pos);
            let masked = try_get_tick_word(self, word_pos) & mask;

            let _initialized = masked != 0;

            let _next = if (_initialized) {
                i32::mul(
                    i32::sub(
                        compressed,
                        i32::sub(
                            i32::from((bit_pos as u32)),
                            i32::from((bit_math::get_most_significant_bit(masked) as u32))
                        )
                    ),
                    tick_spacing_i32
                )
            } else {
                i32::mul(
                    i32::sub(compressed, i32::from((bit_pos as u32))),
                    tick_spacing_i32
                )
            };

            (_next, _initialized)
        } else {
            let (word_pos, bit_pos) = position(i32::add(compressed, i32::from(1)));
            let mask = ((1u256 << bit_pos) - 1) ^ constants::get_max_u256();
            let masked = try_get_tick_word(self, word_pos) & mask;

            let _initialized = masked != 0;
            
            let _next = if (_initialized) {
                i32::mul(
                    i32::add(
                        i32::add(compressed, i32::from(1)),
                        i32::sub(
                            i32::from((bit_math::get_least_significant_bit(masked) as u32)),
                            i32::from((bit_pos as u32))
                        )
                    ),
                    tick_spacing_i32
                )
            } else {
                i32::mul(
                    i32::add(
                        i32::add(compressed, i32::from(1)),
                        i32::sub(
                            i32::from((constants::get_max_u8() as u32)),
                            i32::from((bit_pos as u32))
                        )
                    ),
                    tick_spacing_i32
                )
            };

            (_next, _initialized)
        };

        (next, initialized)
    }

    #[test_only]
    public fun is_initialized(
        tick_bitmap: &Table<I32, u256>,
        tick_index: I32
    ): bool {
        let (next, initialized) = next_initialized_tick_within_one_word(tick_bitmap, tick_index, 1, true);
        if (i32::eq(next, tick_index)) {
            initialized
        } else {
            false
        }
    }

    #[test]
    public fun test_flip_tick() {
        use sui::table;
        use sui::tx_context;
        use flowx_clmm::i32::{Self, I32};
        
        let tick_bitmap = table::new<I32, u256>(&mut tx_context::dummy());

        //is false at first
        assert!(!is_initialized(&tick_bitmap, i32::from(1)), 0);

        //is flipped by #flip_tick
        flip_tick(&mut tick_bitmap, i32::from(1), 1);
        assert!(is_initialized(&tick_bitmap, i32::from(1)), 0);

        //is flipped back by #flip_tick
        flip_tick(&mut tick_bitmap, i32::from(1), 1);
        assert!(!is_initialized(&tick_bitmap, i32::from(1)), 0);

        //is not changed by another flip to a different tick
        flip_tick(&mut tick_bitmap, i32::from(2), 1);
        assert!(!is_initialized(&tick_bitmap, i32::from(1)), 0);

        //is not changed by another flip to a different tick on another word
        flip_tick(&mut tick_bitmap, i32::from(1 + 256), 1);
        assert!(!is_initialized(&tick_bitmap, i32::from(1)), 0);
        assert!(is_initialized(&tick_bitmap, i32::from(257)), 0);

        //flips only the specified tick
        flip_tick(&mut tick_bitmap, i32::neg_from(230), 1);
        assert!(is_initialized(&tick_bitmap, i32::neg_from(230)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(231)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(229)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::from(26)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(486)), 0);

        flip_tick(&mut tick_bitmap, i32::neg_from(230), 1);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(230)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(231)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(229)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::from(26)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(486)), 0);

        //reverts only itself
        flip_tick(&mut tick_bitmap, i32::neg_from(230), 1);
        flip_tick(&mut tick_bitmap, i32::neg_from(259), 1);
        flip_tick(&mut tick_bitmap, i32::neg_from(229), 1);
        flip_tick(&mut tick_bitmap, i32::from(500), 1);
        flip_tick(&mut tick_bitmap, i32::neg_from(259), 1);
        flip_tick(&mut tick_bitmap, i32::neg_from(229), 1);
        flip_tick(&mut tick_bitmap, i32::neg_from(259), 1);
        
        assert!(is_initialized(&tick_bitmap, i32::neg_from(259)), 0);
        assert!(!is_initialized(&tick_bitmap, i32::neg_from(229)), 0);

        table::drop(tick_bitmap);
    }
}