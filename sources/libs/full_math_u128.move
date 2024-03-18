// Copied from: https://github.com/CetusProtocol/integer-mate/blob/main/sui/sources/full_math_u128.move
module flowx_clmm::full_math_u128 {
    const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;

    const LO_128_MASK: u256 = 0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff;

    public fun mul_div_floor(num1: u128, num2: u128, denom: u128): u128 {
        let r = full_mul(num1, num2) / (denom as u256);
        (r as u128)
    }

    public fun mul_div_round(num1: u128, num2: u128, denom: u128): u128 {
        let r = (full_mul(num1, num2) + ((denom as u256) >> 1)) / (denom as u256);
        (r as u128)
    }

    public fun mul_div_ceil(num1: u128, num2: u128, denom: u128): u128 {
        let r = (full_mul(num1, num2) + ((denom as u256) - 1)) / (denom as u256);
        (r as u128)
    }

    public fun mul_shr(num1: u128, num2: u128, shift: u8): u128 {
        let product = full_mul(num1, num2) >> shift;
        (product as u128)
    }

    public fun mul_shl(num1: u128, num2: u128, shift: u8): u128 {
        let product = full_mul(num1, num2) << shift;
        (product as u128)
    }

    public fun full_mul(num1: u128, num2: u128): u256 {
        (num1 as u256) * (num2 as u256)
    }

    /// Return the larger of `x` and `y`
    public fun max(x: u128, y: u128): u128 {
        if (x > y) {
            x
        } else {
            y
        }
    }

    /// Return the smaller of `x` and `y`
    public fun min(x: u128, y: u128): u128 {
        if (x < y) {
            x
        } else {
            y
        }
    }
    
    public fun wrapping_add(n1: u128, n2: u128): u128 {
        let (sum, _) = overflowing_add(n1, n2);
        sum
    }

    public fun overflowing_add(n1: u128, n2: u128): (u128, bool) {
        let sum = (n1 as u256) + (n2 as u256);
        if (sum > (MAX_U128 as u256)) {
            (((sum & LO_128_MASK) as u128), true)
        } else {
            ((sum as u128), false)
        }
    }
    
    public fun wrapping_sub(n1: u128, n2: u128): u128 {
        let (result, _) = overflowing_sub(n1, n2);
        result
    }
    
    public fun overflowing_sub(n1: u128, n2: u128): (u128, bool) {
        if (n1 >= n2) {
            ((n1 - n2), false)
        } else {
            ((MAX_U128 - n2 + n1 + 1), true)
        }
    }
}
