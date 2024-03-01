module flowx_clmm::position {
    use std::type_name::TypeName;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::TxContext;

    use flowx_clmm::i32::I32;
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::full_math_u128;
    use flowx_clmm::constants;
    use flowx_clmm::liquidity_math;

    friend flowx_clmm::pool;

    const E_EMPTY_POSITION: u64 = 1;

    struct Position has key, store {
        id: UID,
        pool_id: ID,
        coin_type_x: TypeName,
	    coin_type_y: TypeName,
        tick_lower_index: I32,
	    tick_upper_index: I32,
        liquidity: u128,
        fee_growth_inside_x_last: u128,
        fee_growth_inside_y_last: u128,
        tokens_owed_x: u64,
        tokens_owed_y: u64
    }

    public(friend) fun create(
        pool_id: ID,
        coin_type_x: TypeName,
	    coin_type_y: TypeName,
        tick_lower_index: I32,
	    tick_upper_index: I32,
        ctx: &mut TxContext
    ): Position {
         Position {
            id: object::new(ctx),
            pool_id,
            coin_type_x,
            coin_type_y,
            tick_lower_index,
            tick_upper_index,
            liquidity: 0,
            fee_growth_inside_x_last: 0,
            fee_growth_inside_y_last: 0,
            tokens_owed_x: 0,
            tokens_owed_y: 0
        }
    }

    public fun tick_lower_index(self: &Position): I32 { self.tick_lower_index }

    public fun tick_upper_index(self: &Position): I32 { self.tick_upper_index }

    public(friend) fun increase_debt(
        self: &mut Position,
        amount_x: u64,
        amount_y: u64
    ) {
        self.tokens_owed_x = self.tokens_owed_x + amount_x;
        self.tokens_owed_y = self.tokens_owed_y + amount_y;
    }

    public(friend) fun update(
        self: &mut Position,
        liquidity_delta: I128,
        fee_growth_inside_x: u128,
        fee_growth_inside_y: u128
    ) {
        let liquidity_next = if (i128::eq(liquidity_delta, i128::zero())) {
            if (self.liquidity == 0) {
                abort E_EMPTY_POSITION
            };
            self.liquidity
        } else {
            liquidity_math::add_delta(self.liquidity, liquidity_delta)
        };

        let tokens_owed_x = full_math_u128::mul_div_floor(
            fee_growth_inside_x - self.fee_growth_inside_x_last,
            self.liquidity,
            constants::get_q64()
        );
        let tokens_owed_y = full_math_u128::mul_div_floor(
            fee_growth_inside_y - self.fee_growth_inside_y_last,
            self.liquidity,
            constants::get_q64()
        );

        self.liquidity = liquidity_next;
        self.fee_growth_inside_x_last = fee_growth_inside_x;
        self.fee_growth_inside_y_last = fee_growth_inside_y;
        self.tokens_owed_x = self.tokens_owed_x + (tokens_owed_x as u64);
        self.tokens_owed_y = self.tokens_owed_y + (tokens_owed_y as u64);
    }
}