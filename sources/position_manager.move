module flowx_clmm::position_mamanger {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::balance;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::transfer;
    use sui::clock::Clock;

    use flowx_clmm::i128;
    use flowx_clmm::tick_math;
    use flowx_clmm::liquidity_math;
    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::tick;
    use flowx_clmm::pool;
    use flowx_clmm::position::{Self, Position};
    use flowx_clmm::versioned::{Self, Versioned};
    use flowx_clmm::pool_manager::{Self, PoolRegistry};
    use flowx_clmm::utils;

    const E_NOT_EMPTY_POSITION: u64 = 0;
    const E_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 1;
    const E_ZERO_COLLECT: u64 = 2;

    struct PositionRegistry has key, store {
        id: UID,
        num_positions: u64
    }

    struct Open has copy, drop, store {
        sender: address,
        pool_id: ID,
        position_id: ID,
        tick_lower_index: I32,
	    tick_upper_index: I32
    }

    struct Close has copy, drop, store {
        sender: address,
        position_id: ID
    }

    struct IncreaseLiquidity has copy, drop, store {
        sender: address,
        pool_id: ID,
        position_id: ID,
        liquidity: u128,
        amount_x: u64,
        amount_y: u64
    }

    struct DecreaseLiquidity has copy, drop, store {
        sender: address,
        pool_id: ID,
        position_id: ID,
        liquidity: u128,
        amount_x: u64,
        amount_y: u64
    }

    public fun open_position<X, Y>(
        self: &mut PositionRegistry,
        pool_registry: &PoolRegistry,
        fee_rate: u64,
        tick_lower_index: I32,
        tick_upper_index: I32,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): Position {
        versioned::check_version_and_upgrade(versioned);
        if (utils::is_ordered<X, Y>()) {
            open_position_<X, Y>(self, pool_registry, fee_rate, tick_lower_index, tick_upper_index, ctx)
        } else {
            open_position_<Y, X>(self, pool_registry, fee_rate, tick_lower_index, tick_upper_index, ctx)
        }
    }

    entry fun open_position_and_transfer<X, Y>(
        self: &mut PositionRegistry,
        pool_registry: &PoolRegistry,
        fee_rate: u64,
        tick_lower_index: u32,
        tick_upper_index: u32,
        recipient: address,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ) {
        transfer::public_transfer(
            open_position<X, Y>(
                self,
                pool_registry,
                fee_rate,
                i32::from_u32(tick_lower_index),
                i32::from_u32(tick_upper_index),
                versioned,
                ctx
            ),
            recipient
        );
    }

    public fun close_position(
        self: &mut PositionRegistry,
        position: Position,
        versioned: &mut Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        if (
            position::liquidity(&position) != 0 ||
            position::coins_owed_x(&position) != 0 ||
            position::coins_owed_y(&position) != 0
        ) {
            abort E_NOT_EMPTY_POSITION
        };

        event::emit(Close {
            sender: tx_context::sender(ctx),
            position_id: object::id(&position)
        });

        position::close(position);
        self.num_positions = self.num_positions - 1;
    }

    public fun increase_liquidity<X, Y>(
        self: &mut PoolRegistry,
        position: &mut Position,
        x_in: Coin<X>,
        y_in: Coin<Y>,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &TxContext
    ) {
        utils::check_deadline(clock, deadline);
        let (amount_x, amount_y) = if (utils::is_ordered<X, Y>()) {
            increase_liquidity_<X, Y>(self, position, x_in, y_in, versioned, ctx)
        } else {
            let (amount_y, amount_x) = increase_liquidity_<Y, X>(self, position, y_in, x_in, versioned, ctx);
            (amount_x, amount_y)
        };

        if (amount_x < amount_x_min || amount_y < amount_y_min) {
            abort E_INSUFFICIENT_OUTPUT_AMOUNT
        };
    }

    public fun decrease_liquidity<X, Y>(
        self: &mut PoolRegistry,
        position: &mut Position,
        liquidity: u128,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &TxContext
    ) {
        utils::check_deadline(clock, deadline);
        let (amount_x, amount_y) = if (utils::is_ordered<X, Y>()) {
            decrease_liquidity_<X, Y>(self, position, liquidity, versioned, ctx)
        } else {
            let (amount_y, amount_x) = decrease_liquidity_<Y, X>(self, position, liquidity, versioned, ctx);
            (amount_x, amount_y)
        };

        if (amount_x < amount_x_min || amount_y < amount_y_min) {
            abort E_INSUFFICIENT_OUTPUT_AMOUNT
        };
    }

    public fun collect<X, Y>(
        self: &mut PoolRegistry,
        position: &mut Position,
        amount_x_requested: u64,
        amount_y_requested: u64,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        if (utils::is_ordered<X, Y>()) {
            collect_<X, Y>(self, position, amount_x_requested, amount_y_requested, versioned, ctx)
        } else {
            let (collectd_y, collectd_x) = collect_<Y, X>(self, position, amount_y_requested, amount_x_requested, versioned, ctx);
            (collectd_x, collectd_y)
        }
    }

    fun open_position_<X, Y>(
        self: &mut PositionRegistry,
        pool_registry: &PoolRegistry,
        fee_rate: u64,
        tick_lower_index: I32,
        tick_upper_index: I32,
        ctx: &mut TxContext
    ): Position {
        tick::check_ticks(tick_lower_index, tick_upper_index);

        let pool = pool_manager::borrow_pool<X, Y>(pool_registry, fee_rate);
        let position = position::open(
            object::id(pool),
            pool::swap_fee_rate(pool),
            pool::coin_type_x(pool),
            pool::coin_type_y(pool),
            tick_lower_index,
            tick_upper_index,
            ctx
        );
        self.num_positions = self.num_positions + 1;

        event::emit(Open {
            sender: tx_context::sender(ctx),
            pool_id: object::id(pool),
            position_id: object::id(&position),
            tick_lower_index,
            tick_upper_index
        });
        
        position
    }

    fun increase_liquidity_<X, Y>(
        self: &mut PoolRegistry,
        position: &mut Position,
        x_in: Coin<X>,
        y_in: Coin<Y>,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (u64, u64) { 
        let pool = pool_manager::borrow_mut_pool<X, Y>(self, position::fee_rate(position));
        let liquidity = liquidity_math::get_liquidity_for_amounts(
            pool::sqrt_price_current(pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(position)),
            coin::value(&x_in),
            coin::value(&y_in)
        );
        let (amount_x, amount_y) = pool::modify_liquidity(
            pool, position, i128::from(liquidity), coin::into_balance(x_in), coin::into_balance(y_in), versioned, ctx
        );

        event::emit(IncreaseLiquidity {
            sender: tx_context::sender(ctx),
            pool_id: object::id(pool),
            position_id: object::id(position),
            liquidity,
            amount_x,
            amount_y
        });

        (amount_x, amount_y)
    }

    fun decrease_liquidity_<X, Y>(
        self: &mut PoolRegistry,
        position: &mut Position,
        liquidity: u128,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (u64, u64) {
        let pool = pool_manager::borrow_mut_pool<X, Y>(self, position::fee_rate(position));
        let (amount_x, amount_y) = pool::modify_liquidity(
            pool, position, i128::neg_from(liquidity), balance::zero(), balance::zero(), versioned, ctx
        );

        event::emit(DecreaseLiquidity {
            sender: tx_context::sender(ctx),
            pool_id: object::id(pool),
            position_id: object::id(position),
            liquidity,
            amount_x,
            amount_y
        });

        (amount_x, amount_y)
    }

    fun collect_<X, Y>(
        self: &mut PoolRegistry,
        position: &mut Position,
        amount_x_requested: u64,
        amount_y_requested: u64,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        if (amount_x_requested == 0 && amount_y_requested == 0) {
            abort E_ZERO_COLLECT
        };

        let pool = pool_manager::borrow_mut_pool<X, Y>(self, position::fee_rate(position));
        if (position::liquidity(position) > 0) {
            pool::modify_liquidity(
                pool, position, i128::zero(), balance::zero(), balance::zero(), versioned, ctx
            );
        };
        
        let (collectd_x, collectd_y) = pool::collect(pool, position, amount_x_requested, amount_y_requested, versioned, ctx);
        (coin::from_balance(collectd_x, ctx), coin::from_balance(collectd_y, ctx))
    }
}