module flowx_clmm::swap_router {
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::transfer;

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
        versioned: &mut Versioned,
        ctx: &TxContext
    ): Balance<Y> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, true, true, coin::value(&coin_in), get_sqrt_price_limit(sqrt_price_limit, true), versioned, ctx
        );
        balance::destroy_zero(x_out);
        pool::pay(pool, receipt, coin::into_balance(coin_in), balance::zero(), versioned);

        y_out
    }

    public fun swap_exact_y_to_x<X, Y>(
        pool: &mut Pool<X, Y>,
        coin_in: Coin<Y>,
        sqrt_price_limit: u128,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): Balance<X> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, false, true, coin::value(&coin_in), get_sqrt_price_limit(sqrt_price_limit, false), versioned, ctx
        );
        balance::destroy_zero(y_out);
        pool::pay(pool, receipt, balance::zero(), coin::into_balance(coin_in), versioned);

        x_out
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
        let coin_out = if (utils::is_ordered<X, Y>()) {
            swap_exact_x_to_y<X, Y>(
                pool_manager::borrow_mut_pool<X, Y>(pool_registry, fee),
                coin_in,
                sqrt_price_limit,
                versioned,
                ctx
            )
        } else {
            swap_exact_y_to_x<Y, X>(
                pool_manager::borrow_mut_pool<Y, X>(pool_registry, fee),
                coin_in,
                sqrt_price_limit,
                versioned,
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
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): Balance<Y> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, true, false, amount_y_out, get_sqrt_price_limit(sqrt_price_limit, true), versioned, ctx
        );
        balance::destroy_zero(x_out);

        let (amount_in_required, _) = pool::receipt_debts(&receipt);
        if (amount_in_required > coin::value(&coin_in)) {
            abort E_EXCESSIVE_INPUT_AMOUNT
        };

        pool::pay(
            pool, receipt, coin::into_balance(coin::split(&mut coin_in, amount_in_required, ctx)), balance::zero(), versioned
        );
        refund(coin_in, tx_context::sender(ctx));
    
        y_out
    }

    public fun swap_y_to_exact_x<X, Y>(
        pool: &mut Pool<X, Y>,
        coin_in: Coin<Y>,
        amount_x_out: u64,
        sqrt_price_limit: u128,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ): Balance<X> {
        let (x_out, y_out, receipt) = pool::swap(
            pool, false, false, amount_x_out, get_sqrt_price_limit(sqrt_price_limit, false), versioned, ctx
        );
        balance::destroy_zero(y_out);

        let (_, amount_in_required) = pool::receipt_debts(&receipt);
        if (amount_in_required > coin::value(&coin_in)) {
            abort E_EXCESSIVE_INPUT_AMOUNT
        };

        pool::pay(
            pool, receipt, balance::zero(), coin::into_balance(coin::split(&mut coin_in, amount_in_required, ctx)), versioned
        );
        refund(coin_in, tx_context::sender(ctx));

        x_out
    }

    public fun swap_exact_output<X, Y>(
        pool_registry: &mut PoolRegistry,
        fee: u64,
        coin_in: Coin<X>,
        amount_out: u64,
        sqrt_price_limit: u128,
        deadline: u64,
        versioned: &mut Versioned,
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
                ctx
            )
        } else {
            swap_y_to_exact_x<Y, X>(
                pool_manager::borrow_mut_pool<Y, X>(pool_registry, fee),
                coin_in,
                amount_out,
                sqrt_price_limit,
                versioned,
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

    #[lint_allow(self_transfer)]
    fun refund<X>(
        refunded: Coin<X>,
        receipt: address
    ) {
        if (coin::value(&refunded) > 0) {
            transfer::public_transfer(refunded, receipt);
        } else {
            coin::destroy_zero(refunded)
        }; 
    }
}