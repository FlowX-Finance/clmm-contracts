module flowx_clmm::pool {
    use std::type_name::{Self, TypeName};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::dynamic_field::{Self as df};
    use sui::event;
    
    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::tick::{Self, TickInfo};
    use flowx_clmm::position::{Self, Position};
    use flowx_clmm::versioned::{Self, Versioned};
    use flowx_clmm::liquidity_math;
    use flowx_clmm::tick_bitmap;
    use flowx_clmm::tick_math;
    use flowx_clmm::sqrt_price_math;

    friend flowx_clmm::pool_manager;

    const E_POOL_ID_MISMATCH: u64 = 0;
    const E_INSUFFICIENT_X: u64 = 1;
    const E_INSUFFICIENT_Y: u64 = 2;
    const E_POOL_ALREADY_INITIALIZED: u64 = 3;

    struct ProtocolFees has store {
        coin_x: u128,
        coin_y: u128 
    }

    struct ReserveDfKey<phantom T> has copy, drop, store {}

    struct Pool<phantom CoinX, phantom CoinY> has key, store {
        id: UID,
        coin_type_x: TypeName,
        coin_type_y: TypeName,
        // the current price
        sqrt_price: u128,
        // the current tick
        tick_index: I32,
        // the pool tick spacing
        tick_spacing: u32,
        max_liquidity_per_tick: u128,
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        protocol_fee_rate: u64,
        // used for the swap fee, either static at initialize or dynamic via hook
        swap_fee_rate: u64,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128,
        protocol_fee_coin_x: u128,
        protocol_fee_coin_y: u128,
        // the currently in range liquidity available to the pool
        liquidity: u128,
        ticks: Table<I32, TickInfo>,
        tick_bitmap: Table<I32, u256>
    }

    struct ModifyLiquidity has copy, drop, store {
        sender: address,
        pool_id: ID,
        position_id: ID,
        tick_lower_index: I32,
        tick_upper_index: I32,
        liquidity_delta: I128,
        amount_x: u64,
        amount_y: u64
    }

    struct Initialize has copy, drop, store {
        pool_id: ID,
        sqrt_price: u128,
        tick_index: I32
    }

    public fun reserve_x<X, Y>(self: &Pool<X, Y>): u64 {
        balance::value(df::borrow<ReserveDfKey<X>, Balance<X>>(&self.id, ReserveDfKey<X> {}))
    }

    public fun reserve_y<X, Y>(self: &Pool<X, Y>): u64 {
        balance::value(df::borrow<ReserveDfKey<Y>, Balance<Y>>(&self.id, ReserveDfKey<Y> {}))
    }

    public(friend) fun create<X, Y>(
        fee_rate: u64,
        tick_spacing: u32,
        ctx: &mut TxContext
    ): Pool<X, Y> {
        let pool = Pool<X, Y> {
            id: object::new(ctx),
            coin_type_x: type_name::get<X>(),
            coin_type_y: type_name::get<Y>(),
            sqrt_price: 0,
            tick_index: i32::zero(),
            tick_spacing,
            max_liquidity_per_tick: tick::tick_spacing_to_max_liquidity_per_tick(tick_spacing),
            protocol_fee_rate: 0,
            swap_fee_rate: fee_rate,
            fee_growth_global_x: 0,
            fee_growth_global_y: 0,
            protocol_fee_coin_x: 0,
            protocol_fee_coin_y: 0,
            liquidity: 0,
            ticks: table::new(ctx),
            tick_bitmap: table::new(ctx)
        };
        df::add(&mut pool.id, ReserveDfKey<X> {}, balance::zero<X>());
        df::add(&mut pool.id, ReserveDfKey<Y> {}, balance::zero<Y>());
        pool
    }

    public fun initialize<X, Y>(
        self: &mut Pool<X, Y>,
        sqrt_price: u128
    ) {
        if (self.sqrt_price > 0) {
            abort E_POOL_ALREADY_INITIALIZED
        };

        let tick_index = tick_math::get_tick_at_sqrt_price(sqrt_price);
        self.tick_index = tick_index;
        self.sqrt_price = sqrt_price;

        event::emit(Initialize {
            pool_id: object::id(self),
            sqrt_price,
            tick_index
        });
    }

    public fun open_position<X, Y>(
        self: &Pool<X, Y>,
        tick_lower_index: I32,
        tick_upper_index: I32,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): Position {
        versioned::check_version_and_upgrade(versioned);
        tick::check_ticks(tick_lower_index, tick_upper_index);

        position::create(
            object::id(self),
            self.coin_type_x,
            self.coin_type_y,
            tick_lower_index,
            tick_upper_index,
            ctx
        )
    }

    public fun modify_liquidity<X, Y>(
        self: &mut Pool<X, Y>,
        position: &mut Position,
        liquidity_delta: I128,
        payment_x: Balance<X>,
        payment_y: Balance<Y>,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (u64, u64) {
        versioned::check_version_and_upgrade(versioned);
        let (pool_id, position_id) = (object::id(self), object::id(position));
        if (pool_id != position_id) {
            abort E_POOL_ID_MISMATCH
        };

        let add = i128::gte(liquidity_delta, i128::zero());
        let (amount_x, amount_y) = modify_position(self, position, liquidity_delta);

        if (add) {
            if (balance::value(&payment_x) < amount_x) {
                abort E_INSUFFICIENT_X
            };
            if (balance::value(&payment_y) < amount_y) {
                abort E_INSUFFICIENT_Y
            };
        } else {
            if (amount_x > 0 || amount_y > 0) {
                position::increase_debt(position, amount_x, amount_y);
            };
        };

        pay(self, payment_x, payment_y);

        event::emit(ModifyLiquidity{
            sender: tx_context::sender(ctx),
            pool_id,
            position_id,
            tick_lower_index: position::tick_lower_index(position),
            tick_upper_index: position::tick_upper_index(position),
            liquidity_delta,
            amount_x,
            amount_y
        });

        (amount_x, amount_y)
    }

    fun pay<X, Y>(
        self: &mut Pool<X, Y>,
        payment_x: Balance<X>,
        payment_y: Balance<Y>,
    ) {
        balance::join(df::borrow_mut(&mut self.id, ReserveDfKey<X> {}), payment_x);
        balance::join(df::borrow_mut(&mut self.id, ReserveDfKey<Y> {}), payment_y);
    }

    fun modify_position<X, Y>(
        pool: &mut Pool<X, Y>,
        position: &mut Position,
        liquidity_delta: I128
    ): (u64, u64) {
        let add = i128::gte(liquidity_delta, i128::zero());
        let (tick_lower_index, tick_upper_index) = (position::tick_lower_index(position), position::tick_upper_index(position));
        let liquidity_delta_abs = i128::abs_u128(liquidity_delta);

        update_position(pool, position, liquidity_delta);

        if (!i128::eq(liquidity_delta, i128::zero())) {
            let (amount_x, amount_y) = if (i32::lt(pool.tick_index, tick_lower_index)) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to right
                (
                    sqrt_price_math::get_amount_x_delta(
                        tick_math::get_sqrt_price_at_tick(tick_lower_index),
                        tick_math::get_sqrt_price_at_tick(tick_upper_index),
                        liquidity_delta_abs,
                        add
                    ),
                    0
                )
            } else if (i32::lt(pool.tick_index, tick_upper_index)) {
                // current tick is inside the passed range
                pool.liquidity = liquidity_math::add_delta(pool.liquidity, liquidity_delta);
                (
                    sqrt_price_math::get_amount_x_delta(
                        pool.sqrt_price,
                        tick_math::get_sqrt_price_at_tick(tick_upper_index),
                        liquidity_delta_abs,
                        add
                    ),
                    sqrt_price_math::get_amount_y_delta(
                        tick_math::get_sqrt_price_at_tick(tick_lower_index),
                        pool.sqrt_price,
                        liquidity_delta_abs,
                        add
                    ),
                )
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to left
                (
                    0,
                    sqrt_price_math::get_amount_y_delta(
                        tick_math::get_sqrt_price_at_tick(tick_lower_index),
                        tick_math::get_sqrt_price_at_tick(tick_upper_index),
                        liquidity_delta_abs,
                        add
                    ),
                )
            };
            (amount_x, amount_y)
        } else {
            (0, 0)
        }
    }

    fun update_position<X, Y>(
        pool: &mut Pool<X, Y>,
        position: &mut Position,
        liquidity_delta: I128
    ) {
        let (tick_lower_index, tick_upper_index) = (position::tick_lower_index(position), position::tick_upper_index(position));
        let (flipped_lower, flipped_upper) = if (!i128::eq(liquidity_delta, i128::zero())) {
            let (flipped_lower_, flipped_upper_) = (
                tick::update(
                    &mut pool.ticks,
                    tick_lower_index,
                    pool.tick_index,
                    liquidity_delta,
                    pool.fee_growth_global_x,
                    pool.fee_growth_global_y,
                    false,
                    pool.max_liquidity_per_tick
                ),
                tick::update(
                    &mut pool.ticks,
                    tick_upper_index,
                    pool.tick_index,
                    liquidity_delta,
                    pool.fee_growth_global_x,
                    pool.fee_growth_global_y,
                    true,
                    pool.max_liquidity_per_tick
                )
            );

            if (flipped_lower_) {
                tick_bitmap::flip_tick(&mut pool.tick_bitmap, tick_lower_index, pool.tick_spacing);
            };
            if (flipped_upper_) {
                tick_bitmap::flip_tick(&mut pool.tick_bitmap, tick_upper_index, pool.tick_spacing);
            };

            (flipped_lower_, flipped_upper_)
        } else {
            (false, false)
        };
        
        let (fee_growth_inside_x, fee_growth_inside_y) =
            tick::get_fee_growth_inside(&pool.ticks, tick_lower_index, tick_upper_index, pool.tick_index, pool.fee_growth_global_x, pool.fee_growth_global_y);

        position::update(position, liquidity_delta, fee_growth_inside_x, fee_growth_inside_y);

        // clear any tick data that is no longer needed
        if (i128::lt(liquidity_delta, i128::zero())) {
            if (flipped_lower) {
                tick::clear(&mut pool.ticks, tick_lower_index);
            };
            if (flipped_upper) {
                tick::clear(&mut pool.ticks, tick_upper_index);
            };
        };
    }
}