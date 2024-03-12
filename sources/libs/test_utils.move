#[test_only]
module flowx_clmm::test_utils {
    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::tick_math;

    #[test_only]
    public fun pow(base: u256, exponent: u8): u256 {
        let res = 1;
        while (exponent >= 1) {
            if (exponent % 2 == 0) {
                base = base * base;
                exponent = exponent / 2;
            } else {
                res = res * base;
                exponent = exponent - 1;
            }
        };

        res
    }

    #[test_only]
    public fun sqrt_u256(y: u256): u256 {
        let z = 0;
        if (y > 3) {
            z = y;
            let x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1
        };
        z
    }

    #[test_only]
    public fun encode_sqrt_price(r_y: u64, r_x: u64): u128 {
        (sqrt_u256(((r_y as u256) << 128) / (r_x as u256)) as u128)
    }

    #[test_only]
    public fun expand_to_9_decimals(n: u64): u64 {
        n * (pow(10, 9) as u64)
    }

    #[test_only]
    public fun get_min_tick(tick_spacing: u32): I32 {
        i32::mul(i32::div(tick_math::min_tick(), i32::from(tick_spacing)), i32::from(tick_spacing))
    }

    #[test_only]
    public fun get_max_tick(tick_spacing: u32): I32 {
        i32::mul(i32::div(tick_math::max_tick(), i32::from(tick_spacing)), i32::from(tick_spacing))
    }
}