module flowx_clmm::liquidity_math {
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::constants;

    const E_OVERFLOW: u64 = 0;
    const E_UNDERFLOW: u64 = 1;

    public fun add_delta(x: u128, y: I128): u128 {
        let abs_y = i128::abs_u128(y);
        if (i128::is_neg(y)) {
            assert!(x >= abs_y, E_UNDERFLOW);
            (x - abs_y)
        } else {
            assert!(abs_y < constants::get_max_u128() - x, E_OVERFLOW);
            (x + abs_y)
        }
    }

    #[test]
    public fun test_add_delta() {
        assert!(add_delta(1, i128::zero()) == 1, 0);
        assert!(add_delta(1, i128::neg_from(1)) == 0, 0);
        assert!(add_delta(1, i128::from(1)) == 2, 0);

        assert!(add_delta(constants::get_max_u128() - 15, i128::from(14)) == constants::get_max_u128() -1, 0);
    }

    #[test]
    #[expected_failure(abort_code = E_OVERFLOW)]
    public fun test_add_delta_fail_if_overflow() {
        add_delta(constants::get_max_u128() - 15, i128::from(15));
    }

    #[test]
    #[expected_failure(abort_code = E_UNDERFLOW)]
    public fun test_add_delta_fail_if_underflow() {
        add_delta(3, i128::neg_from(4));
    }
}