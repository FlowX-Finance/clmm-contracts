module flowx_clmm::swap_router {
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;

    use flowx_clmm::pool_manager::{Self, PoolRegistry};
    use flowx_clmm::tick_math;
    use flowx_clmm::pool::{Self, Pool};
    use flowx_clmm::versioned::Versioned;
    use flowx_clmm::utils;

    const E_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 1;
    const E_EXCESSIVE_INPUT_AMOUNT: u64 = 2;

    public fun swap_exact_x_to_y<X, Y>(
        pool: &mut Pool<X, Y>,
        coin_in: Coin<X>,
        sqrt_price_limit: u128,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &TxContext
    ): Balance<Y> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, true, true, coin::value(&coin_in), get_sqrt_price_limit(sqrt_price_limit, true), versioned, clock, ctx
        );
        balance::destroy_zero(x_out);
        let (amount_x_required, _) = pool::swap_receipt_debts(&receipt);
        pool::pay(pool, receipt, balance::split(coin::balance_mut(&mut coin_in), amount_x_required), balance::zero(), versioned, ctx);
        utils::refund(coin_in, tx_context::sender(ctx));
        y_out
    }

    public fun swap_exact_y_to_x<X, Y>(
        pool: &mut Pool<X, Y>,
        coin_in: Coin<Y>,
        sqrt_price_limit: u128,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &TxContext
    ): Balance<X> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, false, true, coin::value(&coin_in), get_sqrt_price_limit(sqrt_price_limit, false), versioned, clock, ctx
        );
        balance::destroy_zero(y_out);
        let (_, amount_y_required) = pool::swap_receipt_debts(&receipt);
        pool::pay(pool, receipt, balance::zero(), balance::split(coin::balance_mut(&mut coin_in), amount_y_required), versioned, ctx);
        utils::refund(coin_in, tx_context::sender(ctx));
        x_out
    }

    public fun swap_exact_input<X, Y>(
        pool_registry: &mut PoolRegistry,
        fee: u64,
        coin_in: Coin<X>,
        amount_out_min: u64,
        sqrt_price_limit: u128,
        deadline: u64,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Y> {
        utils::check_deadline(clock, deadline);
        let coin_out = if (utils::is_ordered<X, Y>()) {
            swap_exact_x_to_y<X, Y>(
                pool_manager::borrow_mut_pool<X, Y>(pool_registry, fee),
                coin_in,
                sqrt_price_limit,
                versioned,
                clock,
                ctx
            )
        } else {
            swap_exact_y_to_x<Y, X>(
                pool_manager::borrow_mut_pool<Y, X>(pool_registry, fee),
                coin_in,
                sqrt_price_limit,
                versioned,
                clock,
                ctx
            )
        };
        
        if (balance::value<Y>(&coin_out) < amount_out_min) {
            abort E_INSUFFICIENT_OUTPUT_AMOUNT
        };
        
        coin::from_balance(coin_out, ctx)
    }

    public fun swap_x_to_exact_y<X, Y>(
        pool: &mut Pool<X, Y>,
        coin_in: Coin<X>,
        amount_y_out: u64,
        sqrt_price_limit: u128,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): Balance<Y> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, true, false, amount_y_out, get_sqrt_price_limit(sqrt_price_limit, true), versioned, clock, ctx
        );
        balance::destroy_zero(x_out);

        let (amount_in_required, _) = pool::swap_receipt_debts(&receipt);
        if (amount_in_required > coin::value(&coin_in)) {
            abort E_EXCESSIVE_INPUT_AMOUNT
        };

        pool::pay(
            pool, receipt, coin::into_balance(coin::split(&mut coin_in, amount_in_required, ctx)), balance::zero(), versioned, ctx
        );
        utils::refund(coin_in, tx_context::sender(ctx));
    
        y_out
    }

    public fun swap_y_to_exact_x<X, Y>(
        pool: &mut Pool<X, Y>,
        coin_in: Coin<Y>,
        amount_x_out: u64,
        sqrt_price_limit: u128,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): Balance<X> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, false, false, amount_x_out, get_sqrt_price_limit(sqrt_price_limit, false), versioned, clock, ctx
        );
        balance::destroy_zero(y_out);

        let (_, amount_in_required) = pool::swap_receipt_debts(&receipt);
        if (amount_in_required > coin::value(&coin_in)) {
            abort E_EXCESSIVE_INPUT_AMOUNT
        };

        pool::pay(
            pool, receipt, balance::zero(), coin::into_balance(coin::split(&mut coin_in, amount_in_required, ctx)), versioned, ctx
        );
        utils::refund(coin_in, tx_context::sender(ctx));

        x_out
    }

    public fun swap_exact_output<X, Y>(
        pool_registry: &mut PoolRegistry,
        fee: u64,
        coin_in: Coin<X>,
        amount_out: u64,
        sqrt_price_limit: u128,
        deadline: u64,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Y> {
        utils::check_deadline(clock, deadline);

        let coin_out = if (utils::is_ordered<X, Y>()) {
            swap_x_to_exact_y<X, Y>(
                pool_manager::borrow_mut_pool<X, Y>(pool_registry, fee),
                coin_in,
                amount_out,
                sqrt_price_limit,
                versioned,
                clock,
                ctx
            )
        } else {
            swap_y_to_exact_x<Y, X>(
                pool_manager::borrow_mut_pool<Y, X>(pool_registry, fee),
                coin_in,
                amount_out,
                sqrt_price_limit,
                versioned,
                clock,
                ctx
            )
        };

        coin::from_balance(coin_out, ctx)
    }

    fun get_sqrt_price_limit(sqrt_price_limit: u128, x_for_y: bool): u128 {
        if (sqrt_price_limit == 0) {
            if (x_for_y) {
                tick_math::min_sqrt_price() + 1
            } else {
                tick_math::max_sqrt_price() - 1
            }
        } else {
            sqrt_price_limit
        }
    }
}

#[test_only]
module flowx_clmm::test_swap_router {
    use sui::tx_context;
    use sui::sui::SUI;
    use sui::clock;
    use sui::balance;
    use sui::coin;

    use flowx_clmm::i32::I32;
    use flowx_clmm::i128;
    use flowx_clmm::pool_manager::{Self, PoolRegistry};
    use flowx_clmm::versioned;
    use flowx_clmm::pool;
    use flowx_clmm::position;
    use flowx_clmm::tick_math;
    use flowx_clmm::liquidity_math;
    use flowx_clmm::test_utils;
    use flowx_clmm::swap_router;

    struct USDC has drop {}

    #[test_only]
    fun add_liquidity<X, Y>(
        pool_registry: &mut PoolRegistry,
        fee_rate: u64,
        tick_lower: I32,
        tick_upper: I32,
        liquidity: u128
    ) {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool = pool_manager::borrow_mut_pool(pool_registry, fee_rate);
        let (amount_x, amount_y) = liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(pool),
            tick_math::get_sqrt_price_at_tick(tick_lower),
            tick_math::get_sqrt_price_at_tick(tick_upper),
            liquidity,
            true
        );
        let position = position::create_for_testing(
            pool::pool_id(pool), fee_rate, pool::coin_type_x(pool), pool::coin_type_y(pool), tick_lower, tick_upper, &mut ctx
        );
        pool::modify_liquidity<X, Y>(
            pool, &mut position, i128::from(liquidity), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );

        position::destroy_for_testing(position);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_swap_exact_x_to_y() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let pool = pool_manager::borrow_mut_pool<USDC, SUI>(&mut pool_registry, fee_rate);
        let y_out = swap_router::swap_exact_x_to_y<USDC, SUI>(
            pool, coin::mint_for_testing(3, &mut ctx), 0, &mut versioned, &clock, &ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        assert!(
            balance::value(&y_out) == 1 &&
            reserve_x_after == reserve_x_before + 3 &&
            reserve_y_after == reserve_y_before - 1,
            0
        );
        balance::destroy_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_swap_exact_input_x_to_y() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        //x -> y
        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let y_out = swap_router::swap_exact_input<USDC, SUI>(
            &mut pool_registry, fee_rate, coin::mint_for_testing(3, &mut ctx), 1, 0, 1000, &mut versioned, &clock, &mut ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        assert!(
            coin::value(&y_out) == 1 &&
            reserve_x_after == reserve_x_before + 3 &&
            reserve_y_after == reserve_y_before - 1,
            0
        );
        coin::burn_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_swap_exact_y_to_x() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let pool = pool_manager::borrow_mut_pool<USDC, SUI>(&mut pool_registry, fee_rate);
        let y_out = swap_router::swap_exact_y_to_x<USDC, SUI>(
            pool, coin::mint_for_testing(3, &mut ctx), 0, &mut versioned, &clock, &ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        assert!(
            balance::value(&y_out) == 1 &&
            reserve_x_after == reserve_x_before - 1 &&
            reserve_y_after == reserve_y_before + 3,
            0
        );
        balance::destroy_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_swap_exact_input_y_to_x() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        //y -> x
        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let y_out = swap_router::swap_exact_input<SUI, USDC>(
            &mut pool_registry, fee_rate, coin::mint_for_testing(3, &mut ctx), 1, 0, 1000, &mut versioned, &clock, &mut ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        assert!(
            coin::value(&y_out) == 1 &&
            reserve_x_after == reserve_x_before - 1 &&
            reserve_y_after == reserve_y_before + 3,
            0
        );
        coin::burn_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_swap_x_to_exact_y() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        //y -> x
        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let pool = pool_manager::borrow_mut_pool<USDC, SUI>(&mut pool_registry, fee_rate);
        let y_out = swap_router::swap_x_to_exact_y<USDC, SUI>(
            pool, coin::mint_for_testing(101, &mut ctx), 100, 0, &mut versioned, &clock, &mut ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );

        assert!(
            balance::value(&y_out) == 100 &&
            reserve_x_after == reserve_x_before + 101 &&
            reserve_y_after == reserve_y_before - 100,
            0
        );
        balance::destroy_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }


    #[test]
    fun test_swap_exact_output_x_to_y() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        //y -> x
        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let y_out = swap_router::swap_exact_output<USDC, SUI>(
            &mut pool_registry, fee_rate, coin::mint_for_testing(101, &mut ctx), 100, 0, 1000, &mut versioned, &clock, &mut ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );

        assert!(
            coin::value(&y_out) == 100 &&
            reserve_x_after == reserve_x_before + 101 &&
            reserve_y_after == reserve_y_before - 100,
            0
        );
        coin::burn_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_swap_y_to_exact_x() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        //y -> x
        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let pool = pool_manager::borrow_mut_pool<USDC, SUI>(&mut pool_registry, fee_rate);
        let y_out = swap_router::swap_y_to_exact_x<USDC, SUI>(
            pool, coin::mint_for_testing(101, &mut ctx), 100, 0, &mut versioned, &clock, &mut ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );

        assert!(
            balance::value(&y_out) == 100 &&
            reserve_x_after == reserve_x_before - 100 &&
            reserve_y_after == reserve_y_before + 101,
            0
        );
        balance::destroy_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_swap_exact_output_y_to_x() {
        let ctx = tx_context::dummy();
        let (fee_rate, tick_spacing) = (3000, 60);
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, fee_rate, tick_spacing);
        pool_manager::create_and_initialize_pool<SUI, USDC>(&mut pool_registry, fee_rate, test_utils::encode_sqrt_price(1, 1), &mut versioned, &clock, &mut ctx);
        add_liquidity<USDC, SUI>(&mut pool_registry, fee_rate, test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing), 1000000);

        //y -> x
        let (reserve_x_before, reserve_y_before) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );
        let y_out = swap_router::swap_exact_output<SUI, USDC>(
            &mut pool_registry, fee_rate, coin::mint_for_testing(101, &mut ctx), 100, 0, 1000, &mut versioned, &clock, &mut ctx
        );
        let (reserve_x_after, reserve_y_after) = pool::reserves(
            pool_manager::borrow_pool<USDC, SUI>(&pool_registry, fee_rate)
        );

        assert!(
            coin::value(&y_out) == 100 &&
            reserve_x_after == reserve_x_before - 100 &&
            reserve_y_after == reserve_y_before + 101,
            0
        );
        coin::burn_for_testing(y_out);

        pool_manager::destroy_for_testing(pool_registry);
        versioned::destroy_for_testing(versioned);
        clock::destroy_for_testing(clock);
    }
}