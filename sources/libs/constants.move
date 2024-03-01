module flowx_clmm::constants {
    const MAX_U8: u8 = 0xff;
    const MAX_U16: u16 = 0xffff;
    const MAX_U32: u32 = 0xffffffff;
    const MAX_U64: u64 = 0xffffffffffffffff;
    const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;
    const MAX_U256: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    const Q64: u128 = 0x10000000000000000;
    const FEE_RATE_DENOMINATOR_VALUE: u64 = 1_000_000u64;

    public fun get_max_u8(): u8 {
        MAX_U8
    }

    public fun get_max_u16(): u16 {
        MAX_U16
    }

    public fun get_max_u32(): u32 {
        MAX_U32
    }

    public fun get_max_u64(): u64 {
        MAX_U64
    }

    public fun get_max_u128(): u128 {
        MAX_U128
    }

    public fun get_max_u256(): u256 {
        MAX_U256
    }

    public fun get_q64(): u128 {
        Q64
    }

    public fun get_fee_rate_denominator_value(): u64 {
        FEE_RATE_DENOMINATOR_VALUE
    }
}