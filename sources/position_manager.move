module flowx_clmm::position_manager {
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
    use flowx_clmm::i32::I32;
    use flowx_clmm::tick;
    use flowx_clmm::pool;
    use flowx_clmm::position::{Self, Position};
    use flowx_clmm::versioned::{Self, Versioned};
    use flowx_clmm::pool_manager::{Self, PoolRegistry};
    use flowx_clmm::utils;

    const E_NOT_EMPTY_POSITION: u64 = 0;
    const E_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 1;
    const E_ZERO_COLLECT: u64 = 2;
    const E_NOT_ORDERED: u64 = 3;

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

    fun init(ctx: &mut TxContext) {
        transfer::share_object(PositionRegistry {
            id: object::new(ctx),
            num_positions: 0
        });
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
        utils::check_order<X, Y>();
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
        ctx: &mut TxContext
    ) {
        utils::check_order<X, Y>();
        utils::check_deadline(clock, deadline);
        let pool = pool_manager::borrow_mut_pool<X, Y>(self, position::fee_rate(position));
        
        let (sqrt_price_current, sqrt_price_a, sqrt_price_b) =
            (pool::sqrt_price_current(pool), tick_math::get_sqrt_price_at_tick(position::tick_lower_index(position)), tick_math::get_sqrt_price_at_tick(position::tick_upper_index(position)));
        let liquidity = liquidity_math::get_liquidity_for_amounts(
            sqrt_price_current,
            sqrt_price_a,
            sqrt_price_b,
            coin::value(&x_in),
            coin::value(&y_in)
        );

        let (amount_x_required, amount_y_required) = liquidity_math::get_amounts_for_liquidity(
            sqrt_price_current,
            sqrt_price_a,
            sqrt_price_b,
            liquidity,
            true
        );

        if (amount_x_required < amount_x_min || amount_y_required < amount_y_min) {
            abort E_INSUFFICIENT_OUTPUT_AMOUNT
        };

        let (amount_x, amount_y) = pool::modify_liquidity(
            pool, position, i128::from(liquidity), coin::into_balance(coin::split(&mut x_in, amount_x_required, ctx)),
            coin::into_balance(coin::split(&mut y_in, amount_y_required, ctx)), versioned, clock, ctx
        );
        utils::refund(x_in, tx_context::sender(ctx));
        utils::refund(y_in, tx_context::sender(ctx));

        event::emit(IncreaseLiquidity {
            sender: tx_context::sender(ctx),
            pool_id: object::id(pool),
            position_id: object::id(position),
            liquidity,
            amount_x,
            amount_y
        });
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
        utils::check_order<X, Y>();
        utils::check_deadline(clock, deadline);
        let pool = pool_manager::borrow_mut_pool<X, Y>(self, position::fee_rate(position));
        let (amount_x, amount_y) = pool::modify_liquidity(
            pool, position, i128::neg_from(liquidity), balance::zero(), balance::zero(), versioned, clock, ctx
        );

        if (amount_x < amount_x_min || amount_y < amount_y_min) {
            abort E_INSUFFICIENT_OUTPUT_AMOUNT
        };

        event::emit(DecreaseLiquidity {
            sender: tx_context::sender(ctx),
            pool_id: object::id(pool),
            position_id: object::id(position),
            liquidity,
            amount_x,
            amount_y
        });
    }

    public fun collect<X, Y>(
        self: &mut PoolRegistry,
        position: &mut Position,
        amount_x_requested: u64,
        amount_y_requested: u64,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        utils::check_order<X, Y>();
        utils::check_zero_amount(amount_x_requested);
        utils::check_zero_amount(amount_y_requested);

        let pool = pool_manager::borrow_mut_pool<X, Y>(self, position::fee_rate(position));
        if (position::liquidity(position) > 0) {
            pool::modify_liquidity(
                pool, position, i128::zero(), balance::zero(), balance::zero(), versioned, clock, ctx
            );
        };
        
        let (collected_x, collectd_y) = pool::collect(pool, position, amount_x_requested, amount_y_requested, versioned, ctx);
        (coin::from_balance(collected_x, ctx), coin::from_balance(collectd_y, ctx))
    }

    public fun collect_pool_reward<X, Y, RewardCoinType>(
        self: &mut PoolRegistry,
        position: &mut Position,
        amount_requested: u64,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<RewardCoinType> {
        utils::check_order<X, Y>();
        utils::check_zero_amount(amount_requested);

        let pool = pool_manager::borrow_mut_pool<X, Y>(self, position::fee_rate(position));
        if (position::liquidity(position) > 0) {
            pool::modify_liquidity(
                pool, position, i128::zero(), balance::zero(), balance::zero(), versioned, clock, ctx
            );
        };
        
        coin::from_balance(
            pool::collect_pool_reward<X, Y, RewardCoinType>(pool, position, amount_requested, versioned, ctx),
            ctx
        )
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): PositionRegistry {
        PositionRegistry {
            id: object::new(ctx),
            num_positions: 0
        }
    }

    #[test_only]
    public fun destroy_for_testing(position_registry: PositionRegistry) {
        let PositionRegistry { id, num_positions: _ } = position_registry;
        object::delete(id);
    }

    #[test_only]
    public fun open_for_testing<X, Y>(
        position_registry: &mut PositionRegistry,
        pool_registry: &PoolRegistry,
        fee_rate: u64,
        tick_lower_index: I32,
        tick_upper_index: I32,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): Position {
        open_position<X, Y>(position_registry, pool_registry, fee_rate, tick_lower_index, tick_upper_index, versioned, ctx)
    }
}

#[test_only]
module flowx_clmm::test_position_manager {
    use sui::tx_context;
    use sui::clock;
    use sui::coin;

    use flowx_clmm::i32;
    use flowx_clmm::versioned;
    use flowx_clmm::pool_manager;
    use flowx_clmm::position_manager;
    use flowx_clmm::position;
    use flowx_clmm::test_utils;

    struct USDT has drop {}
    struct USDC has drop {}
    struct SCB has drop {}

    #[test]
    fun test_increase_liquidy() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        let position_registry = position_manager::create_for_testing(&mut ctx);
        let (fee_rate, tick_spacing) = (3000, 60);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);

        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        pool_manager::create_and_initialize_pool<SCB, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        let position = position_manager::open_for_testing<SCB, USDC>(
            &mut position_registry, &pool_registry, fee_rate, min_tick, max_tick, &mut versioned, &mut ctx
        );
        position_manager::increase_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            coin::mint_for_testing(1000, &mut ctx),
            coin::mint_for_testing(1000, &mut ctx),
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );
        assert!(position::liquidity(&position) == 1000, 0);
        assert!(position::fee_rate(&position) == fee_rate, 0);
        assert!(i32::eq(position::tick_lower_index(&position), min_tick), 0);
        assert!(i32::eq(position::tick_upper_index(&position), max_tick), 0);
        assert!(position::coins_owed_x(&position) == 0, 0);
        assert!(position::coins_owed_y(&position) == 0, 0);
        assert!(position::fee_growth_inside_x_last(&position) == 0, 0);
        assert!(position::fee_growth_inside_y_last(&position) == 0, 0);

        position_manager::increase_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            coin::mint_for_testing(100, &mut ctx),
            coin::mint_for_testing(100, &mut ctx),
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );
        assert!(position::liquidity(&position) == 1100, 0);
        assert!(position::fee_rate(&position) == fee_rate, 0);
        assert!(i32::eq(position::tick_lower_index(&position), min_tick), 0);
        assert!(i32::eq(position::tick_upper_index(&position), max_tick), 0);
        assert!(position::coins_owed_x(&position) == 0, 0);
        assert!(position::coins_owed_y(&position) == 0, 0);
        assert!(position::fee_growth_inside_x_last(&position) == 0, 0);
        assert!(position::fee_growth_inside_y_last(&position) == 0, 0);

        position::destroy_for_testing(position);
        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
        position_manager::destroy_for_testing(position_registry);
    }

    #[test]
    fun test_decrease_liquidy() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        let position_registry = position_manager::create_for_testing(&mut ctx);
        let (fee_rate, tick_spacing) = (3000, 60);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);

        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        pool_manager::create_and_initialize_pool<SCB, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        let position = position_manager::open_for_testing<SCB, USDC>(
            &mut position_registry, &pool_registry, fee_rate, min_tick, max_tick, &mut versioned, &mut ctx
        );
        position_manager::increase_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            coin::mint_for_testing(100, &mut ctx),
            coin::mint_for_testing(100, &mut ctx),
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );

        position_manager::decrease_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            25,
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );
        assert!(position::liquidity(&position) == 75, 0);
        assert!(position::fee_rate(&position) == fee_rate, 0);
        assert!(i32::eq(position::tick_lower_index(&position), min_tick), 0);
        assert!(i32::eq(position::tick_upper_index(&position), max_tick), 0);
        assert!(position::coins_owed_x(&position) == 24, 0);
        assert!(position::coins_owed_y(&position) == 24, 0);
        assert!(position::fee_growth_inside_x_last(&position) == 0, 0);
        assert!(position::fee_growth_inside_y_last(&position) == 0, 0);

        //can decrease for all the liquidity
        position_manager::decrease_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            75,
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );
        assert!(position::liquidity(&position) == 0, 0);
        assert!(position::fee_rate(&position) == fee_rate, 0);
        assert!(i32::eq(position::tick_lower_index(&position), min_tick), 0);
        assert!(i32::eq(position::tick_upper_index(&position), max_tick), 0);
        assert!(position::coins_owed_x(&position) == 98, 0);
        assert!(position::coins_owed_y(&position) == 98, 0);
        assert!(position::fee_growth_inside_x_last(&position) == 0, 0);
        assert!(position::fee_growth_inside_y_last(&position) == 0, 0);

        position::destroy_for_testing(position);
        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
        position_manager::destroy_for_testing(position_registry);
    }
    
    #[test]
    #[expected_failure(abort_code = flowx_clmm::liquidity_math::E_UNDERFLOW)]
    fun test_decrease_liquidy_fail_if_exceed_max_amount() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        let position_registry = position_manager::create_for_testing(&mut ctx);
        let (fee_rate, tick_spacing) = (3000, 60);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);

        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        pool_manager::create_and_initialize_pool<SCB, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        let position = position_manager::open_for_testing<SCB, USDC>(
            &mut position_registry, &pool_registry, fee_rate, min_tick, max_tick, &mut versioned, &mut ctx
        );
        position_manager::increase_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            coin::mint_for_testing(100, &mut ctx),
            coin::mint_for_testing(100, &mut ctx),
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );

        position_manager::decrease_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            101,
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );

        position::destroy_for_testing(position);
        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
        position_manager::destroy_for_testing(position_registry);
    }

    #[test]
    fun test_collect() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        let position_registry = position_manager::create_for_testing(&mut ctx);
        let (fee_rate, tick_spacing) = (3000, 60);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);

        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        pool_manager::create_and_initialize_pool<SCB, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        let position = position_manager::open_for_testing<SCB, USDC>(
            &mut position_registry, &pool_registry, fee_rate, min_tick, max_tick, &mut versioned, &mut ctx
        );
        position_manager::increase_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            coin::mint_for_testing(100, &mut ctx),
            coin::mint_for_testing(100, &mut ctx),
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );

        position_manager::decrease_liquidity<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            100,
            0,
            0,
            1000,
            &mut versioned,
            &clock,
            &mut ctx
        );
        assert!(position::liquidity(&position) == 0, 0);
        assert!(position::fee_rate(&position) == fee_rate, 0);
        assert!(i32::eq(position::tick_lower_index(&position), min_tick), 0);
        assert!(i32::eq(position::tick_upper_index(&position), max_tick), 0);
        assert!(position::coins_owed_x(&position) == 99, 0);
        assert!(position::coins_owed_y(&position) == 99, 0);
        assert!(position::fee_growth_inside_x_last(&position) == 0, 0);
        assert!(position::fee_growth_inside_y_last(&position) == 0, 0);

        let (x_out, y_out) = position_manager::collect<SCB, USDC>(
            &mut pool_registry,
            &mut position,
            flowx_clmm::constants::get_max_u64(),
            flowx_clmm::constants::get_max_u64(),
            &mut versioned,
            &clock,
            &mut ctx
        );
        assert!(coin::value(&x_out) == 99, 0);
        assert!(coin::value(&y_out) == 99, 0);
        assert!(position::liquidity(&position) == 0, 0);
        assert!(position::fee_rate(&position) == fee_rate, 0);
        assert!(i32::eq(position::tick_lower_index(&position), min_tick), 0);
        assert!(i32::eq(position::tick_upper_index(&position), max_tick), 0);
        assert!(position::coins_owed_x(&position) == 0, 0);
        assert!(position::coins_owed_y(&position) == 0, 0);
        assert!(position::fee_growth_inside_x_last(&position) == 0, 0);
        assert!(position::fee_growth_inside_y_last(&position) == 0, 0);
        coin::burn_for_testing(x_out);
        coin::burn_for_testing(y_out);

        position::destroy_for_testing(position);
        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
        position_manager::destroy_for_testing(position_registry);
    }
}