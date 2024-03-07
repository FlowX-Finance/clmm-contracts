module flowx_clmm::oracle {
    use std::vector;

    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::i64::{Self, I64};
    use flowx_clmm::math_u256;

    friend flowx_clmm::pool;

    struct Observation has copy, drop, store {
        timestamp_s: u64,
        tick_cumulative: I64,
        seconds_per_liquidity_cumulative: u256,
        initialized: bool
    }

    fun default(): Observation {
        Observation {
            timestamp_s: 0,
            tick_cumulative: i64::zero(),
            seconds_per_liquidity_cumulative: 0,
            initialized: false
        }
    }

    public(friend) fun transform(
        last: &Observation,
        timestamp_s: u64,
        tick_index: I32,
        liquidity: u128
    ): Observation {
        let tick_index_i64 = if (i32::is_neg(tick_index)) {
            i64::neg_from((i32::abs_u32(tick_index) as u64))
        } else {
            i64::from((i32::abs_u32(tick_index) as u64))
        };

        let timestamp_delta = timestamp_s - last.timestamp_s;
        let liquidity_delta = if (liquidity == 0) {
            1
        } else {
            liquidity
        };

        Observation {
            timestamp_s,
            tick_cumulative: i64::add(tick_index_i64, i64::mul(tick_index_i64, i64::from(timestamp_delta))),
            seconds_per_liquidity_cumulative: math_u256::overflow_add(
                last.seconds_per_liquidity_cumulative, ((timestamp_delta as u256) << 128) / (liquidity_delta as u256)
            ),
            initialized: true
        }
    }

    public(friend) fun initialize(self: &mut vector<Observation>, timestamp_s: u64): (u64, u64) {
        vector::push_back(self, Observation {
            timestamp_s,
            tick_cumulative: i64::zero(),
            seconds_per_liquidity_cumulative: 0,
            initialized: true
        });

        (1, 1)
    }

    public(friend) fun write(
        self: &mut vector<Observation>,
        index: u64,
        time: u64,
        tick_index: I32,
        liquidity: u128,
        cardinality: u64,
        cardinality_next: u64
    ): (u64, u64) {
        let last_index = vector::length(self) - 1;
        let last = vector::borrow(self, last_index);


        if (last.timestamp_s == time) {
            return (index, cardinality)
        };

        let cardinality_updated = if (cardinality_next > cardinality && index == (cardinality - 1)) {
            cardinality_next
        } else {
            cardinality
        };

        let index_updated = (index + 1) % cardinality_updated;
        let transformed = transform(last, time, tick_index, liquidity);
        let observation = vector::borrow_mut(self, index_updated);
        observation.timestamp_s = transformed.timestamp_s;
        observation.tick_cumulative = transformed.tick_cumulative;
        observation.seconds_per_liquidity_cumulative = transformed.seconds_per_liquidity_cumulative;
        observation.initialized = transformed.initialized;

        (index, cardinality_updated)
    }

    public(friend) fun grow(
        self: &mut vector<Observation>,
        current: u64,
        next: u64
    ): u64 {
        if (current == 0) {
            abort 0
        };

        if (next <= current) {
            return 0
        };

        while(current < next) {
            vector::push_back(self, Observation {
                timestamp_s: 1,
                tick_cumulative: i64::zero(),
                seconds_per_liquidity_cumulative: 0,
                initialized: false
            });
            current = current + 1;
        };

        next
    }

    fun try_get_observation(
        self: &vector<Observation>,
        index: u64
    ): Observation {
        if (index > vector::length(self) - 1) {
            default()
        } else {
            *vector::borrow(self, index)
        }
    }

    public fun binary_search(
        self: &vector<Observation>,
        time: u64,
        target: u64,
        index: u64,
        cardinality: u64
    ): (Observation, Observation) {
        let l = (index + 1)  % cardinality;
        let r = l + cardinality - 1;

        let i = 0;
        let before_or_at = default();
        let at_or_after = default();
        while(true) {
            i = (l + r) / 2;
                        
            before_or_at = try_get_observation(self, i % cardinality);

            if (!before_or_at.initialized) {
                l = i + 1;
                continue;
            };

            at_or_after = try_get_observation(self, (i + 1) % cardinality);

            let target_at_of_after = before_or_at.timestamp_s <= target;

            if (target_at_of_after && target <= at_or_after.timestamp_s) break;

            if (!target_at_of_after) {
                r = i - 1;
            } else {
                l = i + 1;
            };
        };

        (before_or_at, at_or_after)
    }

    public fun get_surrounding_observations(
        self: &vector<Observation>,
        time: u64,
        target: u64,
        tick_index: I32,
        index: u64,
        liquidity: u128,
        cardinality: u64
    ): (Observation, Observation) {
        let before_or_at = try_get_observation(self, index);
        let at_or_after = default();

        if (before_or_at.timestamp_s <= target) {
            if (before_or_at.timestamp_s == target) {
                return (before_or_at, at_or_after)
            } else {
                return (before_or_at, transform(&before_or_at, target, tick_index, liquidity))
            }
        };

        before_or_at = try_get_observation(self, (index + 1) % cardinality);
        if (!before_or_at.initialized) {
            before_or_at = *vector::borrow(self, 0);
        };

        if (before_or_at.timestamp_s <= target) {
            abort 0
        };
        
        binary_search(self, time, target, index, cardinality)
    }

    public fun observe_single(
        self: &vector<Observation>,
        time: u64,
        seconds_ago: u64,
        tick_index: I32,
        index: u64,
        liquidity: u128,
        cardinality: u64
    ): (I64, u256) {
        if (seconds_ago == 0) {
            let last = try_get_observation(self, index);
            if (last.timestamp_s != time) {
                last = transform(&last, time, tick_index, liquidity)
            };

            return (last.tick_cumulative, last.seconds_per_liquidity_cumulative)
        };

        let target = time - seconds_ago;
        
        let (before_or_at, at_or_after) = get_surrounding_observations(
            self, time, target, tick_index, index, liquidity, cardinality
        );

        if (target == before_or_at.timestamp_s) {
            (before_or_at.tick_cumulative, before_or_at.seconds_per_liquidity_cumulative)
        } else if (target == at_or_after.timestamp_s) {
            (at_or_after.tick_cumulative, at_or_after.seconds_per_liquidity_cumulative)
        } else {
            let observation_time_delta = at_or_after.timestamp_s - before_or_at.timestamp_s;
            let target_delta = target - before_or_at.timestamp_s;

            (
                i64::add(
                    before_or_at.tick_cumulative,
                    i64::mul(
                        i64::div(
                            i64::add(at_or_after.tick_cumulative, before_or_at.tick_cumulative),
                            i64::from(observation_time_delta)
                        ),
                        i64::from(target_delta)
                    )
                ),
                before_or_at.seconds_per_liquidity_cumulative + 
                    (
                        ((
                            at_or_after.seconds_per_liquidity_cumulative - before_or_at.seconds_per_liquidity_cumulative
                        ) * (target_delta as u256)) / (observation_time_delta as u256)
                    )
            )
        }
    }

    public fun observe(
        self: &vector<Observation>,
        time: u64,
        seconds_agos: vector<u64>,
        tick_index: I32,
        index: u64,
        liquidity: u128,
        cardinality: u64
    ): (vector<I64>, vector<u256>) {
        if (cardinality == 0) {
            abort 0
        };

        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = (vector::empty<I64>(), vector::empty<u256>());
        let (i, len) = (0, vector::length(&seconds_agos));
        while (i < len) {
            let (tick_cumulative, seconds_per_liquidity_cumulative) = observe_single(
                self,
                time,
                *vector::borrow(&seconds_agos, i),
                tick_index,
                index,
                liquidity,
                cardinality
            );
            vector::push_back(&mut tick_cumulatives, tick_cumulative);
            vector::push_back(&mut seconds_per_liquidity_cumulatives, seconds_per_liquidity_cumulative);
            i = i + 1;
        };

        (tick_cumulatives, seconds_per_liquidity_cumulatives)
    }
}