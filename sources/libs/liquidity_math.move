module flowx_clmm::liquidity_math {
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::constants;
    use flowx_clmm::full_math_u128;
    use flowx_clmm::math_u256;

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
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = sort_sqrt_prices(sqrt_ratio_a, sqrt_ratio_b);
        let intermediate = full_math_u128::mul_div_floor(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, (constants::get_q64() as u128));
        full_math_u128::mul_div_floor((amount_x as u128), intermediate, sqrt_ratio_b_sorted - sqrt_ratio_a_sorted)
    }

    public fun get_liquidity_for_amount_y(
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        amount_y: u64
    ): u128 {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = sort_sqrt_prices(sqrt_ratio_a, sqrt_ratio_b);
        full_math_u128::mul_div_floor((amount_y as u128), (constants::get_q64() as u128), sqrt_ratio_b_sorted - sqrt_ratio_a_sorted)
    }

    public fun get_liquidity_for_amounts(
        sqrt_ratio_x: u128,
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        amount_x: u64,
        amount_y: u64
    ): u128 {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = sort_sqrt_prices(sqrt_ratio_a, sqrt_ratio_b);
        let liquidity = if (sqrt_ratio_x <= sqrt_ratio_a_sorted) {
            get_liquidity_for_amount_x(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, amount_x)
        } else if (sqrt_ratio_x < sqrt_ratio_b_sorted){
            let liquidity0 = get_liquidity_for_amount_x(sqrt_ratio_x, sqrt_ratio_b_sorted, amount_x);
            let liquidity1 = get_liquidity_for_amount_y(sqrt_ratio_a_sorted, sqrt_ratio_x, amount_y);
            full_math_u128::min(liquidity0, liquidity1)
        } else {
            get_liquidity_for_amount_y(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, amount_y)
        };
        liquidity
    }

    public fun get_amount_x_for_liquidity(
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        liquidity: u128,
    ): u64 {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = sort_sqrt_prices(sqrt_ratio_a, sqrt_ratio_b);
        let sqrt_ratio_diff = sqrt_ratio_b_sorted - sqrt_ratio_a_sorted;
        
        let (numerator, overflowing) = math_u256::checked_shlw(
            full_math_u128::full_mul(liquidity, sqrt_ratio_diff)
        );

        if (overflowing) {
            abort E_OVERFLOW
        };

        let denominator = full_math_u128::full_mul(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted);
        (math_u256::div_round(numerator, denominator, true) as u64)
    }

    public fun get_amount_y_for_liquidity(
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        liquidity: u128,
    ): u64 {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = sort_sqrt_prices(sqrt_ratio_a, sqrt_ratio_b);
        let sqrt_ratio_diff = sqrt_ratio_b_sorted - sqrt_ratio_a_sorted;
        (
            (
                math_u256::div_round(
                    full_math_u128::full_mul(liquidity, sqrt_ratio_diff), (constants::get_q64() as u256),
                    true
                ) as u64
            )
        )
    }

    public fun get_amounts_for_liquidity(
        sqrt_ratio_x: u128,
        sqrt_ratio_a: u128,
        sqrt_ratio_b: u128,
        liquidity: u128,
    ): (u64, u64) {
        let (sqrt_ratio_a_sorted, sqrt_ratio_b_sorted) = sort_sqrt_prices(sqrt_ratio_a, sqrt_ratio_b);
        if (sqrt_ratio_x <= sqrt_ratio_a_sorted) {
            (get_amount_x_for_liquidity(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, liquidity), 0)
        } else if (sqrt_ratio_x < sqrt_ratio_b_sorted) {
            (
                get_amount_x_for_liquidity(sqrt_ratio_x, sqrt_ratio_b_sorted, liquidity),
                get_amount_y_for_liquidity(sqrt_ratio_a_sorted, sqrt_ratio_x, liquidity),
            )
        } else {
            (0, get_amount_y_for_liquidity(sqrt_ratio_a_sorted, sqrt_ratio_b_sorted, liquidity))
        }
    }

    fun sort_sqrt_prices(sqrt_ratio_a: u128, sqrt_ratio_b: u128): (u128, u128) {
        if (sqrt_ratio_a > sqrt_ratio_b) {
            (sqrt_ratio_b, sqrt_ratio_a)
        } else {
            (sqrt_ratio_a, sqrt_ratio_b)
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

    #[test]
    public fun test_get_liquidity_for_amounts() {
        use flowx_clmm::test_utils;

        //amounts for price inside
        let sqrt_price_x = test_utils::encode_sqrt_price(1, 1);
        let sqrt_price_a = test_utils::encode_sqrt_price(100, 110);
        let sqrt_price_b = test_utils::encode_sqrt_price(110, 100);
        let liquidity = get_liquidity_for_amounts(
            sqrt_price_x,
            sqrt_price_a,
            sqrt_price_b,
            100,
            200
        );
        assert!(liquidity == 2148, 0);

        //amounts for price below
        let sqrt_price_x = test_utils::encode_sqrt_price(99, 110);
        let sqrt_price_a = test_utils::encode_sqrt_price(100, 110);
        let sqrt_price_b = test_utils::encode_sqrt_price(110, 100);
        let liquidity = get_liquidity_for_amounts(
            sqrt_price_x,
            sqrt_price_a,
            sqrt_price_b,
            100,
            200
        );
        assert!(liquidity == 1048, 0);

        //amounts for price above
        let sqrt_price_x = test_utils::encode_sqrt_price(111, 100);
        let sqrt_price_a = test_utils::encode_sqrt_price(100, 110);
        let sqrt_price_b = test_utils::encode_sqrt_price(110, 100);
        let liquidity = get_liquidity_for_amounts(
            sqrt_price_x,
            sqrt_price_a,
            sqrt_price_b,
            100,
            200
        );
        assert!(liquidity == 2097, 0);

        //amounts for price equal to lower boundary
        let sqrt_price_a = test_utils::encode_sqrt_price(100, 110);
        let sqrt_price_x = sqrt_price_a;
        let sqrt_price_b = test_utils::encode_sqrt_price(110, 100);
        let liquidity = get_liquidity_for_amounts(
            sqrt_price_x,
            sqrt_price_a,
            sqrt_price_b,
            100,
            200
        );
        assert!(liquidity == 1048, 0);

        //amounts for price equal to upper boundary
        let sqrt_price_a = test_utils::encode_sqrt_price(100, 110);
        let sqrt_price_b = test_utils::encode_sqrt_price(110, 100);
        let sqrt_price_x = sqrt_price_b;
        let liquidity = get_liquidity_for_amounts(
            sqrt_price_x,
            sqrt_price_a,
            sqrt_price_b,
            100,
            200
        );
        assert!(liquidity == 2097, 0);
    }
}