module flowx_clmm::liquidity_math {
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::constants;
    use flowx_clmm::full_math_u128;

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

    public fun get_liquidity_for_amount_x(
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        amount_x: u64
    ): u128 {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = if (sqrt_ratio_a > sqrt_ratio_b) {
            (sqrt_ratio_b, sqrt_ratio_a)
        } else {
            (sqrt_ratio_a, sqrt_ratio_b)
        };

        let intermediate = full_math_u128::mul_div_floor(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, (constants::get_q64() as u128));
        full_math_u128::mul_div_floor((amount_x as u128), intermediate, sqrt_ratio_b_sorted - sqrt_ratio_a_sorted)
    }

    public fun get_liquidity_for_amount_y(
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        amount_y: u64
    ): u128 {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = if (sqrt_ratio_a > sqrt_ratio_b) {
            (sqrt_ratio_b, sqrt_ratio_a)
        } else {
            (sqrt_ratio_a, sqrt_ratio_b)
        };

        full_math_u128::mul_div_floor((amount_y as u128), (constants::get_q64() as u128), sqrt_ratio_b_sorted - sqrt_ratio_a_sorted)
    }

    public fun get_liquidity_for_amounts(
        sqrt_ratio_x: u128,
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        amount_x: u64,
        amount_y: u64
    ): u128 {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = if (sqrt_ratio_a > sqrt_ratio_b) {
            (sqrt_ratio_b, sqrt_ratio_a)
        } else {
            (sqrt_ratio_a, sqrt_ratio_b)
        };

        let liquidity = if (sqrt_ratio_x <= sqrt_ratio_a_sorted) {
            get_liquidity_for_amount_x(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, amount_x)
        } else if (sqrt_ratio_x < sqrt_ratio_b_sorted){
            let liquidity0 = get_liquidity_for_amount_x(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, amount_x);
            let liquidity1 = get_liquidity_for_amount_y(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, amount_y);
            full_math_u128::min(liquidity0, liquidity1)
        } else {
            get_liquidity_for_amount_y(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, amount_y)
        };
        liquidity
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