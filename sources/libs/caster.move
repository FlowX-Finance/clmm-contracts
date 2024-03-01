module flowx_clmm::caster {
    use flowx_clmm::i32::{Self, I32};

    const E_OVERFLOW: u64 = 0;

    public fun cast_to_u8(x: I32): u8 {
        assert!(i32::abs_u32(x) < 256, E_OVERFLOW);
        ((i32::abs_u32(i32::add(x, i32::from(256))) & 0xFF) as u8)
    }

    #[test]
    fun test_cast_to_u8() {
        assert!(cast_to_u8(i32::neg_from(1)) == 255, 0);
        assert!(cast_to_u8(i32::neg_from(2)) == 254, 0);

        assert!(cast_to_u8(i32::from(1)) == 1, 0);
        assert!(cast_to_u8(i32::from(255)) == 255, 0);
    }
}