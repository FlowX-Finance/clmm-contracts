module flowx_clmm::swap_router {
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::transfer;

    use flowx_clmm::pool_manager::{Self, PoolRegistry};
    use flowx_clmm::tick_math;
    use flowx_clmm::pool::{Self, Pool, Receipt};
    use flowx_clmm::versioned::Versioned;
    use flowx_clmm::utils;

    const E_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 1;
    const E_EXCESSIVE_INPUT_AMOUNT: u64 = 2;

    public fun swap_exact_x_to_y<X, Y>(
        pool: &mut Pool<X, Y>,
        amount_x_in: u64,
        sqrt_price_limit: u128,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): (Balance<Y>, Receipt) {
        let _sqrt_price_limit = if (sqrt_price_limit == 0) {
            tick_math::min_sqrt_price() + 1
        } else {
            sqrt_price_limit
        };

        let (x_out, y_out, receipt) = pool::swap(
            pool,
            true,
            true,
            amount_x_in,
            _sqrt_price_limit,
            versioned,
            ctx
        );
        
        balance::destroy_zero(x_out);

        (y_out, receipt)
    }

    public fun swap_exact_y_to_x<X, Y>(
        pool: &mut Pool<X, Y>,
        amount_y_in: u64,
        sqrt_price_limit: u128,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): (Balance<X>, Receipt) {
        let _sqrt_price_limit = if (sqrt_price_limit == 0) {
            tick_math::max_sqrt_price() - 1
        } else {
            sqrt_price_limit
        };

        let (x_out, y_out, receipt) = pool::swap(
            pool,
            true,
            true,
            amount_y_in,
            _sqrt_price_limit,
            versioned,
            ctx
        );
        balance::destroy_zero(y_out);

        (x_out, receipt)
    }

    public fun swap_exact_input<X, Y>(
        pool_registry: &mut PoolRegistry,
        fee: u64,
        coin_in: Coin<X>,
        amount_out_min: u64,
        sqrt_price_limit: u128,
        deadline: u64,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Y> {
        utils::check_deadline(clock, deadline);
        let amount_in = coin::value(&coin_in);
        let coin_out = if (utils::is_ordered<X, Y>()) {
            let pool = pool_manager::borrow_mut_pool<X, Y>(pool_registry, fee);
            let (coin_out, receipt) = swap_exact_x_to_y<X, Y>(
                pool,
                amount_in,
                sqrt_price_limit,
                versioned,
                ctx
            );
            pool::pay(
                pool,
                receipt,
                coin::into_balance(coin_in),
                balance::zero(),
                versioned,
                ctx
            );
            coin_out
        } else {
            let pool = pool_manager::borrow_mut_pool<Y, X>(pool_registry, fee);
            let (coin_out, receipt) = swap_exact_y_to_x<Y, X>(
                pool,
                amount_in,
                sqrt_price_limit,
                versioned,
                ctx
            );
            pool::pay(
                pool,
                receipt,
                balance::zero(),
                coin::into_balance(coin_in),
                versioned,
                ctx
            );
            coin_out
        };
        
        if (balance::value<Y>(&coin_out) < amount_out_min) {
            abort E_INSUFFICIENT_OUTPUT_AMOUNT
        };
        
        coin::from_balance(coin_out, ctx)
    }

    public fun swap_x_to_exact_y<X, Y>(
        pool: &mut Pool<X, Y>,
        amount_y_out: u64,
        sqrt_price_limit: u128,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): (Balance<Y>, Receipt) {
        let _sqrt_price_limit = if (sqrt_price_limit == 0) {
            tick_math::min_sqrt_price() + 1
        } else {
            sqrt_price_limit
        };

        let (x_out, y_out, receipt) = pool::swap(
            pool,
            true,
            false,
            amount_y_out,
            _sqrt_price_limit,
            versioned,
            ctx
        );

        balance::destroy_zero(x_out);
        (y_out, receipt)
    }

    public fun swap_y_to_exact_x<X, Y>(
        pool: &mut Pool<X, Y>,
        amount_x_out: u64,
        sqrt_price_limit: u128,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): (Balance<X>, Receipt) {
        let _sqrt_price_limit = if (sqrt_price_limit == 0) {
            tick_math::max_sqrt_price() - 1
        } else {
            sqrt_price_limit
        };

        let (x_out, y_out, receipt) = pool::swap(
            pool,
            true,
            false,
            amount_x_out,
            _sqrt_price_limit,
            versioned,
            ctx
        );

        balance::destroy_zero(y_out);
        (x_out, receipt)
    }

    #[lint_allow(self_transfer)]
    public fun swap_exact_output<X, Y>(
        pool_registry: &mut PoolRegistry,
        fee: u64,
        coin_in: Coin<X>,
        amount_in_max: u64,
        amount_out: u64,
        sqrt_price_limit: u128,
        deadline: u64,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Y> {
        utils::check_deadline(clock, deadline);

        let amount_in_max = coin::value(&coin_in);
        let (coin_out, amount_in_required) = if (utils::is_ordered<X, Y>()) {
            let pool = pool_manager::borrow_mut_pool<X, Y>(pool_registry, fee);
            let (coin_out, receipt) = swap_x_to_exact_y<X, Y>(
                pool,
                amount_out,
                sqrt_price_limit,
                versioned,
                ctx
            );
            let (amount_in_required, _) = pool::receipt_debts(&receipt);
            pool::pay(
                pool,
                receipt,
                coin::into_balance(coin::split(&mut coin_in, amount_in_required, ctx)),
                balance::zero(),
                versioned,
                ctx
            );
            (coin_out, amount_in_required)
        } else {
            let pool = pool_manager::borrow_mut_pool<Y, X>(pool_registry, fee);
            let (coin_out, receipt) = swap_y_to_exact_x<Y, X>(
                pool,
                amount_out,
                sqrt_price_limit,
                versioned,
                ctx
            );
            let (_, amount_in_required) = pool::receipt_debts(&receipt);
            pool::pay(
                pool,
                receipt,
                balance::zero(),
                coin::into_balance(coin::split(&mut coin_in, amount_in_required, ctx)),
                versioned,
                ctx
            );
            (coin_out, amount_in_required)
        };
        
        if (amount_in_required > amount_in_max) {
            abort E_EXCESSIVE_INPUT_AMOUNT
        };
        if (coin::value(&coin_in) > 0) {
            transfer::public_transfer(coin_in, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(coin_in)
        };
        
        coin::from_balance(coin_out, ctx)
    }
}