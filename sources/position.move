module flowx_clmm::position {
    use std::vector;
    use std::string::utf8;
    use std::type_name::TypeName;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::display;
    use sui::package;
    use sui::transfer;

    use flowx_clmm::i32::I32;
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::full_math_u128;
    use flowx_clmm::constants;
    use flowx_clmm::liquidity_math;
    use flowx_clmm::full_math_u64;

    friend flowx_clmm::pool;
    friend flowx_clmm::position_manager;

    const E_EMPTY_POSITION: u64 = 0;
    const E_COINS_OWED_OVERFLOW: u64 = 1;

    struct POSITION has drop {}

    struct Position has key, store {
        id: UID,
        pool_id: ID,
        fee_rate: u64,
        coin_type_x: TypeName,
	    coin_type_y: TypeName,
        tick_lower_index: I32,
	    tick_upper_index: I32,
        liquidity: u128,
        fee_growth_inside_x_last: u128,
        fee_growth_inside_y_last: u128,
        coins_owed_x: u64,
        coins_owed_y: u64,
        reward_infos: vector<PositionRewardInfo>
    }

    struct PositionRewardInfo has copy, store, drop {
        reward_growth_inside_last: u128,
        coins_owed_reward: u64,
    }

    fun init(otw: POSITION, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);
        let display = display::new<Position>(&publisher, ctx);
        display::add(&mut display, utf8(b"name"), utf8(b"Flowx Position's NFT"));
        display::add(&mut display, utf8(b"description"), utf8(b"Flowx Position's NFT"));
        display::add(&mut display, utf8(b"image_url"), utf8(b""));
        display::update_version(&mut display);

        transfer::public_transfer(display, tx_context::sender(ctx));
        transfer::public_transfer(publisher, tx_context::sender(ctx));
    }

    public fun pool_id(self: &Position): ID { self.pool_id }

    public fun fee_rate(self: &Position): u64 { self.fee_rate }

    public fun liquidity(self: &Position): u128 { self.liquidity }

    public fun tick_lower_index(self: &Position): I32 { self.tick_lower_index }

    public fun tick_upper_index(self: &Position): I32 { self.tick_upper_index }

    public fun coins_owed_x(self: &Position): u64 { self.coins_owed_x }

    public fun coins_owed_y(self: &Position): u64 { self.coins_owed_y }

    public fun fee_growth_inside_x_last(self: &Position): u128 { self.fee_growth_inside_x_last }

    public fun fee_growth_inside_y_last(self: &Position): u128 { self.fee_growth_inside_y_last }

    public fun reward_growth_inside_last(self: &Position, i: u64): u128 {
        let len = vector::length(&self.reward_infos);
        if (i >= len) {
            0
        } else {
            vector::borrow(&self.reward_infos, i).reward_growth_inside_last
        }
    }

    public fun coins_owed_reward(self: &Position, i: u64): u64 {
        let len = vector::length(&self.reward_infos);
        if (i >= len) {
            0
        } else {
            vector::borrow(&self.reward_infos, i).coins_owed_reward
        }
    }

    fun try_borrow_mut_reward_info(self: &mut Position, i: u64): &mut PositionRewardInfo {
        let len = vector::length(&self.reward_infos);
        if (i >= len) {
            vector::push_back(&mut self.reward_infos, PositionRewardInfo {
                reward_growth_inside_last: 0,
                coins_owed_reward: 0
            });
        };

        vector::borrow_mut(&mut self.reward_infos, i)
    }

    public(friend) fun open(
        pool_id: ID,
        fee_rate: u64,
        coin_type_x: TypeName,
	    coin_type_y: TypeName,
        tick_lower_index: I32,
	    tick_upper_index: I32,
        ctx: &mut TxContext
    ): Position {
        Position {
            id: object::new(ctx),
            pool_id,
            fee_rate,
            coin_type_x,
            coin_type_y,
            tick_lower_index,
            tick_upper_index,
            liquidity: 0,
            fee_growth_inside_x_last: 0,
            fee_growth_inside_y_last: 0,
            coins_owed_x: 0,
            coins_owed_y: 0,
            reward_infos: vector::empty()
        }
    }

    public(friend) fun close(position: Position) {
        let Position { 
            id, pool_id: _, fee_rate: _, coin_type_x: _, coin_type_y: _, tick_lower_index: _, tick_upper_index: _,
            liquidity: _, fee_growth_inside_x_last: _, fee_growth_inside_y_last: _, coins_owed_x: _, coins_owed_y: _, reward_infos: _
        } = position;
        object::delete(id);
    }

    public(friend) fun increase_debt(
        self: &mut Position,
        amount_x: u64,
        amount_y: u64
    ) {
        self.coins_owed_x = self.coins_owed_x + amount_x;
        self.coins_owed_y = self.coins_owed_y + amount_y;
    }

    public(friend) fun decrease_debt(
        self: &mut Position,
        amount_x: u64,
        amount_y: u64
    ) {
        self.coins_owed_x = self.coins_owed_x - amount_x;
        self.coins_owed_y = self.coins_owed_y - amount_y;
    }

    public(friend) fun decrease_reward_debt(
        self: &mut Position,
        i: u64,
        amount: u64
    ) {
        let reward_info = try_borrow_mut_reward_info(self, i);
        reward_info.coins_owed_reward = reward_info.coins_owed_reward - amount;
    }

    public(friend) fun update(
        self: &mut Position,
        liquidity_delta: I128,
        fee_growth_inside_x: u128,
        fee_growth_inside_y: u128,
        reward_growths_inside: vector<u128>
    ) {
        let liquidity_next = if (i128::eq(liquidity_delta, i128::zero())) {
            if (self.liquidity == 0) {
                abort E_EMPTY_POSITION
            };
            self.liquidity
        } else {
            liquidity_math::add_delta(self.liquidity, liquidity_delta)
        };

        let coins_owed_x = full_math_u128::mul_div_floor(
            full_math_u128::wrapping_sub(fee_growth_inside_x, self.fee_growth_inside_x_last),
            self.liquidity,
            constants::get_q64()
        );
        let coins_owed_y = full_math_u128::mul_div_floor(
            full_math_u128::wrapping_sub(fee_growth_inside_y, self.fee_growth_inside_y_last),
            self.liquidity,
            constants::get_q64()
        );

        if (coins_owed_x > (constants::get_max_u64() as u128) || coins_owed_y > (constants::get_max_u64() as u128)) {
            abort E_COINS_OWED_OVERFLOW
        };

        if (
            !full_math_u64::add_check(self.coins_owed_x, (coins_owed_x as u64)) ||
            !full_math_u64::add_check(self.coins_owed_x, (coins_owed_x as u64))
        ) {
            abort E_COINS_OWED_OVERFLOW
        };

        update_reward_infos(self, reward_growths_inside);
        self.liquidity = liquidity_next;
        self.fee_growth_inside_x_last = fee_growth_inside_x;
        self.fee_growth_inside_y_last = fee_growth_inside_y;
        self.coins_owed_x = self.coins_owed_x + (coins_owed_x as u64);
        self.coins_owed_y = self.coins_owed_y + (coins_owed_y as u64);
    }

    fun update_reward_infos(
        self: &mut Position,
        reward_growths_inside: vector<u128>
    ) {
        let (i, num_rewards) = (0, vector::length(&reward_growths_inside));
        while(i < num_rewards) {
            let liquidity = self.liquidity;
            let reward_growth_inside = *vector::borrow(&reward_growths_inside, i);
            let reward_info = try_borrow_mut_reward_info(self, i);
            let coins_owed_reward = full_math_u128::mul_div_floor(
                full_math_u128::wrapping_sub(reward_growth_inside, reward_info.reward_growth_inside_last),
                liquidity,
                constants::get_q64()
            );

            if (
                coins_owed_reward > (constants::get_max_u64() as u128) ||
                !full_math_u64::add_check(reward_info.coins_owed_reward, (coins_owed_reward as u64))
            ) {
                abort E_COINS_OWED_OVERFLOW
            };

            reward_info.reward_growth_inside_last = reward_growth_inside;
            reward_info.coins_owed_reward = reward_info.coins_owed_reward + (coins_owed_reward as u64);
        };
    }

    #[test_only]
    public fun create_for_testing(
        pool_id: ID,
        fee_rate: u64,
        coin_type_x: TypeName,
	    coin_type_y: TypeName,
        tick_lower_index: I32,
	    tick_upper_index: I32,
        ctx: &mut TxContext
    ): Position {
        open(pool_id, fee_rate, coin_type_x, coin_type_y, tick_lower_index, tick_upper_index, ctx)
    }

    #[test_only]
    public fun destroy_for_testing(position: Position) {
        let Position { 
            id, pool_id: _, fee_rate: _, coin_type_x: _, coin_type_y: _, tick_lower_index: _, tick_upper_index: _,
            liquidity: _, fee_growth_inside_x_last: _, fee_growth_inside_y_last: _, coins_owed_x: _, coins_owed_y: _, reward_infos: _
        } = position;
        object::delete(id);
    }
}