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

    #[test_only]
    public fun init_tick(): Table<I32, u256> {
        use std::vector;
        let tick_indexs = vector<I32> [
            i32::neg_from(200),
            i32::neg_from(55),
            i32::neg_from(4),
            i32::from(70),
            i32::from(78),
            i32::from(84),
            i32::from(139),
            i32::from(240),
            i32::from(535),
        ];

        let tick_bitmap = table::new<I32, u256>(&mut sui::tx_context::dummy());
        let (i, len) = (0, vector::length(&tick_indexs));
        while(i < len) {
            flip_tick(&mut tick_bitmap, *vector::borrow(&mut tick_indexs, i), 1);
            i = i + 1;
        };
        tick_bitmap
    }

    #[test]
    public fun test_next_initialized_tick_within_one_word_lte_false() {
        //returns tick to right if at initialized tick
        let tick_bitmap = init_tick();
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(78), 1, false);
        assert!(i32::eq(next, i32::from(84)) && initialized, 0);
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::neg_from(55), 1, false);
        assert!(i32::eq(next, i32::neg_from(4)) && initialized, 0);

        //returns the tick directly to the right
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(77), 1, false);
        assert!(i32::eq(next, i32::from(78)) && initialized, 0);
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::neg_from(56), 1, false);
        assert!(i32::eq(next, i32::neg_from(55)) && initialized, 0);

        //returns the next words initialized tick if on the right boundary
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(255), 1, false);
        assert!(i32::eq(next, i32::from(511)) && !initialized, 0);
        
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::neg_from(257), 1, false);
        assert!(i32::eq(next, i32::neg_from(200)) && initialized, 0);

        //returns the next initialized tick from the next word
        flip_tick(&mut tick_bitmap, i32::from(340), 1);
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(328), 1, false);
        assert!(i32::eq(next, i32::from(340)) && initialized, 0);

        flip_tick(&mut tick_bitmap, i32::from(340), 1);

        //does not exceed boundary
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(508), 1, false);
        assert!(i32::eq(next, i32::from(511)) && !initialized, 0);

        //skips entire word
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(255), 1, false);
        assert!(i32::eq(next, i32::from(511)) && !initialized, 0);

        //skips half word
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(383), 1, false);
        assert!(i32::eq(next, i32::from(511)) && !initialized, 0);

        table::drop(tick_bitmap);
    }

    #[test]
    public fun test_next_initialized_tick_within_one_word_lte_true() {
        let tick_bitmap = init_tick();

        //returns same tick if initialized
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(78), 1, true);
        assert!(i32::eq(next, i32::from(78)) && initialized, 0);

        //returns tick directly to the left of input tick if not initialized
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(79), 1, true);
        assert!(i32::eq(next, i32::from(78)) && initialized, 0);

        //will not exceed the word boundary
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(258), 1, true);
        assert!(i32::eq(next, i32::from(256)) && !initialized, 0);

        //at the word boundary
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(256), 1, true);
        assert!(i32::eq(next, i32::from(256)) && !initialized, 0);

        //word boundary less 1 (next initialized tick in next word
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(72), 1, true);
        assert!(i32::eq(next, i32::from(70)) && initialized, 0);

        //word boundary
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::neg_from(257), 1, true);
        assert!(i32::eq(next, i32::neg_from(512)) && !initialized, 0);

        //entire empty word
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(1023), 1, true);
        assert!(i32::eq(next, i32::from(768)) && !initialized, 0);

        //halfway through empty word
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(900), 1, true);
        assert!(i32::eq(next, i32::from(768)) && !initialized, 0);

        //boundary is initialized
        flip_tick(&mut tick_bitmap, i32::from(329), 1);
        let (next, initialized) = next_initialized_tick_within_one_word(&tick_bitmap, i32::from(456), 1, true);
        assert!(i32::eq(next, i32::from(329)) && initialized, 0);        

        table::drop(tick_bitmap);
    }
}