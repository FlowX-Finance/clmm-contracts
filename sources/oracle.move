module flowx_clmm::oracle {
    use std::vector;

    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::i64::{Self, I64};
    use flowx_clmm::math_u256;

    friend flowx_clmm::pool;
    
    const E_NOT_INITIALIZED: u64 = 0;
    const E_OLDEST_OBSERVATION: u64 = 1;

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

    public fun timestamp_s(self: &Observation): u64 { self.timestamp_s }

    public fun tick_cumulative(self: &Observation): I64 { self.tick_cumulative }

    public fun seconds_per_liquidity_cumulative(self: &Observation): u256 { self.seconds_per_liquidity_cumulative }

    public fun is_initialized(self: &Observation): bool { self.initialized }

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
            tick_cumulative: i64::add(last.tick_cumulative, i64::mul(tick_index_i64, i64::from(timestamp_delta))),
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
        let last = vector::borrow(self, index);

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

        (index_updated, cardinality_updated)
    }

    public(friend) fun grow(
        self: &mut vector<Observation>,
        current: u64,
        next: u64
    ): u64 {
        if (current == 0) {
            abort E_NOT_INITIALIZED
        };

        if (next <= current) {
            return current
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
                continue
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

        if (before_or_at.timestamp_s > target) {
            abort E_OLDEST_OBSERVATION
        };
        
        binary_search(self, target, index, cardinality)
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
            self, target, tick_index, index, liquidity, cardinality
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
                            i64::sub(at_or_after.tick_cumulative, before_or_at.tick_cumulative),
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
            abort E_NOT_INITIALIZED
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

    #[test_only]
    struct Oracle has drop {
        time: u64,
        tick: I32,
        liquidity: u128,
        index: u64,
        cardinality: u64,
        cardinality_next: u64,
        observations: vector<Observation>
    }

    #[test_only]
    fun initialize_for_testing(time: u64, tick: I32, liquidity: u128): Oracle {
        let oracle = Oracle {
            time,
            tick,
            liquidity,
            index: 0,
            cardinality: 0,
            cardinality_next: 0,
            observations: vector::empty()
        };

        let (cardinality, cardinality_next) = initialize(&mut oracle.observations, time);
        oracle.cardinality = cardinality;
        oracle.cardinality_next = cardinality_next;
        oracle
    }

    #[test_only]
    fun grow_for_testing(oracle: &mut Oracle, _cardinality_next: u64) {
        let current = oracle.cardinality_next;
        let cardinality_next = grow(&mut oracle.observations, current, _cardinality_next);
        oracle.cardinality_next = cardinality_next;
    }

    #[test_only]
    fun update_for_testing(oracle: &mut Oracle, time: u64, tick: I32, liquidity: u128) {
        oracle.time = oracle.time + time;
        let (c_index, c_tick, c_time, c_liquidity, c_cardinality, c_cardinality_next) = 
            (oracle.index, oracle.tick, oracle.time, oracle.liquidity, oracle.cardinality, oracle.cardinality_next);
        let (index, cardinality) = write(&mut oracle.observations, c_index, c_time, c_tick, c_liquidity, c_cardinality, c_cardinality_next);
        oracle.index = index;
        oracle.cardinality = cardinality;
        oracle.tick = tick;
        oracle.liquidity = liquidity;
    }

    #[test_only]
    fun observe_for_testing(oracle: &Oracle, seconds_agos: vector<u64>): (vector<I64>, vector<u256>) {
        let (time, tick, index, liquidity, cardinality) = (oracle.time, oracle.tick, oracle.index, oracle.liquidity, oracle.cardinality);
        observe(&oracle.observations, time, seconds_agos, tick, index, liquidity, cardinality)
    }

    #[test]
    public fun test_grow() {
        let oracle = initialize_for_testing(0, i32::zero(), 0);

        //increases the cardinality next for the first call
        grow_for_testing(&mut oracle, 5);
        assert!(oracle.index == 0 && oracle.cardinality == 1 && oracle.cardinality_next == 5, 0);

        //does not touch the first slot
        let observation_at_0 = vector::borrow(&oracle.observations, 0);
        assert!(
            observation_at_0.timestamp_s == 0 && 
            i64::eq(observation_at_0.tick_cumulative, i64::zero()) &&
            observation_at_0.seconds_per_liquidity_cumulative == 0 &&
            observation_at_0.initialized,
            0
        );

        //is no op if oracle is already gte that size
        grow_for_testing(&mut oracle, 3);
        let i = 1;
        while (i < 5) {
            let observation = vector::borrow(&oracle.observations, i);
            assert!(
                observation.timestamp_s == 1 && 
                i64::eq(observation.tick_cumulative, i64::zero()) &&
                observation.seconds_per_liquidity_cumulative == 0 &&
                !observation.initialized,
                0
            );
            i = i + 1;
        };

        //grow after wrap
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 2, i32::from(1), 1);    //index is now 1
        assert!(oracle.index == 1, 0);
        update_for_testing(&mut oracle, 2, i32::from(1), 1);    //index is now 0 again
        assert!(oracle.index == 0, 0);
        grow_for_testing(&mut oracle, 3);
        assert!(oracle.index == 0 && oracle.cardinality == 2 && oracle.cardinality_next == 3, 0);
    }

    #[test]
    fun test_write() {
        // single element array gets overwritten
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        update_for_testing(&mut oracle, 1, i32::from(2), 5);
        assert!(oracle.index == 0, 0);
        let observation_at_0 = vector::borrow(&oracle.observations, 0);
        assert!(
            observation_at_0.timestamp_s == 1 && 
            i64::eq(observation_at_0.tick_cumulative, i64::zero()) &&
            observation_at_0.seconds_per_liquidity_cumulative == 340282366920938463463374607431768211456 &&
            observation_at_0.initialized,
            0
        );
        update_for_testing(&mut oracle, 5, i32::neg_from(1), 8);
        assert!(oracle.index == 0, 0);
        let observation_at_0 = vector::borrow(&oracle.observations, 0);
        assert!(
            observation_at_0.timestamp_s == 6 && 
            i64::eq(observation_at_0.tick_cumulative, i64::from(10)) &&
            observation_at_0.seconds_per_liquidity_cumulative == 680564733841876926926749214863536422912 &&
            observation_at_0.initialized,
            0
        );

        update_for_testing(&mut oracle, 3, i32::from(2), 3);
        assert!(oracle.index == 0, 0);
        let observation_at_0 = vector::borrow(&oracle.observations, 0);
        assert!(
            observation_at_0.timestamp_s == 9 && 
            i64::eq(observation_at_0.tick_cumulative, i64::from(7)) &&
            observation_at_0.seconds_per_liquidity_cumulative == 808170621437228850725514692650449502208 &&
            observation_at_0.initialized,
            0
        );

        //does nothing if time has not changed
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 1, i32::from(3), 2);
        assert!(oracle.index == 1, 0);
        update_for_testing(&mut oracle, 0, i32::neg_from(5), 9);
        assert!(oracle.index == 1, 0);

        //writes an index if time has changed
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 3);
        update_for_testing(&mut oracle, 6, i32::from(3), 2);
        assert!(oracle.index == 1, 0);
        update_for_testing(&mut oracle, 4, i32::neg_from(5), 9);
        assert!(oracle.index == 2, 0);
        let observation_at_1 = vector::borrow(&oracle.observations, 1);
        assert!(
            observation_at_1.timestamp_s == 6 && 
            i64::eq(observation_at_1.tick_cumulative, i64::zero()) &&
            observation_at_1.seconds_per_liquidity_cumulative == 2041694201525630780780247644590609268736 &&
            observation_at_1.initialized,
            0
        );

        //grows cardinality when writing past
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 3);
        grow_for_testing(&mut oracle, 4);
        assert!(oracle.cardinality == 1, 0);
        update_for_testing(&mut oracle, 3, i32::from(5), 6);
        assert!(oracle.cardinality == 4, 0);
        update_for_testing(&mut oracle, 4, i32::from(6), 4);
        assert!(oracle.index == 2, 0);
        let observation_at_2 = vector::borrow(&oracle.observations, 2);
        assert!(
            observation_at_2.timestamp_s == 7 && 
            i64::eq(observation_at_2.tick_cumulative, i64::from(20)) &&
            observation_at_2.seconds_per_liquidity_cumulative == 1247702012043441032699040227249816775338 &&
            observation_at_2.initialized,
            0
        );

        //wraps around
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 3);
        update_for_testing(&mut oracle, 3, i32::from(1), 2);
        update_for_testing(&mut oracle, 4, i32::from(2), 3);
        update_for_testing(&mut oracle, 5, i32::from(3), 4);
        assert!(oracle.index == 0, 0);
        let observation_at_0 = vector::borrow(&oracle.observations, 0);
        assert!(
            observation_at_0.timestamp_s == 12 && 
            i64::eq(observation_at_0.tick_cumulative, i64::from(14)) &&
            observation_at_0.seconds_per_liquidity_cumulative == 2268549112806256423089164049545121409706 &&
            observation_at_0.initialized,
            0
        );

        //accumulates liquidity
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 4);
        update_for_testing(&mut oracle, 3, i32::from(3), 2);
        update_for_testing(&mut oracle, 4, i32::neg_from(7), 6);
        update_for_testing(&mut oracle, 5, i32::neg_from(2), 4);
        assert!(oracle.index == 3, 0);
        let observation_at_1 = vector::borrow(&oracle.observations, 1);
        assert!(
            observation_at_1.timestamp_s == 3 && 
            i64::eq(observation_at_1.tick_cumulative, i64::from(0)) &&
            observation_at_1.seconds_per_liquidity_cumulative == 1020847100762815390390123822295304634368 &&
            observation_at_1.initialized,
            0
        );
        let observation_at_2 = vector::borrow(&oracle.observations, 2);
        assert!(
            observation_at_2.timestamp_s == 7 && 
            i64::eq(observation_at_2.tick_cumulative, i64::from(12)) &&
            observation_at_2.seconds_per_liquidity_cumulative == 1701411834604692317316873037158841057280 &&
            observation_at_2.initialized,
            0
        );
        let observation_at_3 = vector::borrow(&oracle.observations, 3);
        assert!(
            observation_at_3.timestamp_s == 12 && 
            i64::eq(observation_at_3.tick_cumulative, i64::neg_from(23)) &&
            observation_at_3.seconds_per_liquidity_cumulative == 1984980473705474370203018543351981233493 &&
            observation_at_3.initialized,
            0
        );
        assert!(vector::length(&oracle.observations) == 4, 0);
    }

    #[test]
    fun test_observe() {
        //does not fail across overflow boundary
        let oracle = initialize_for_testing(0, i32::zero(), flowx_clmm::constants::get_max_u128());
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 13, i32::zero(), 0);
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 13,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(6));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 7,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(12));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 1,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(13));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 0,
            0
        );

        //interpolates correctly at min liquidity
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 13, i32::zero(), flowx_clmm::constants::get_max_u128());
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 13 << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(6));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 7 << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(12));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 1 << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(13));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 0,
            0
        );

        //interpolates the same as 0 liquidity for 1 liquidity
        let oracle = initialize_for_testing(0, i32::zero(), 1);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 13, i32::zero(), flowx_clmm::constants::get_max_u128());
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 13 << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(6));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 7 << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(12));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 1 << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(13));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 0,
            0
        );

        //interpolates correctly across seconds boundaries
        let oracle = initialize_for_testing(0, i32::zero(), 0);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 1 << 32, i32::zero(), 0);
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == (1 << 32) << 128,
            0
        );
        update_for_testing(&mut oracle, 13, i32::zero(), 0);
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == ((1 << 32) + 13) << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(3));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == ((1 << 32) + 10) << 128,
            0
        );
        let (_, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(8));
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == ((1 << 32) + 5) << 128,
            0
        );

        //single observation at current time
        let oracle = initialize_for_testing(5, i32::from(2), 4);
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::zero()) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 0,
            0
        );

        //single observation in past at exactly seconds ago
        let oracle = initialize_for_testing(5, i32::from(2), 4);
        oracle.time = oracle.time + 3;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(3));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::zero()) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 0,
            0
        );

        //single observation in past counterfactual in past
        let oracle = initialize_for_testing(5, i32::from(2), 4);
        oracle.time = oracle.time + 3;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(1));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::from(4)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 170141183460469231731687303715884105728,
            0
        );

        //single observation in past counterfactual now
        let oracle = initialize_for_testing(5, i32::from(2), 4);
        oracle.time = oracle.time + 3;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::from(6)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 255211775190703847597530955573826158592,
            0
        );

        //two observations in chronological order 0 seconds ago exact
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(20)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 272225893536750770770699685945414569164,
            0
        );

        //two observations in chronological order 0 seconds ago counterfactual
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        oracle.time = oracle.time + 7;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(13)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 1463214177760035392892510811956603309260,
            0
        );

        //two observations in chronological order seconds ago is exactly on first observation
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        oracle.time = oracle.time + 7;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(11));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(0)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 0,
            0
        );

        //two observations in chronological order seconds ago is between first and second
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        oracle.time = oracle.time + 7;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(9));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(10)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 136112946768375385385349842972707284582,
            0
        );

        //two observations in reverse order 0 seconds ago exact
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        update_for_testing(&mut oracle, 3, i32::neg_from(5), 4);
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(17)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 782649443918158465965761597093066886348,
            0
        );

        //two observations in reverse order 0 seconds ago counterfactual
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        update_for_testing(&mut oracle, 3, i32::neg_from(5), 4);
        oracle.time = oracle.time + 7;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(0));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(52)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 1378143586029800777026667160098661256396,
            0
        );

        //two observations in reverse order seconds ago is exactly on first observation
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        update_for_testing(&mut oracle, 3, i32::neg_from(5), 4);
        oracle.time = oracle.time + 7;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(10));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(20)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 272225893536750770770699685945414569164,
            0
        );

        //two observations in reverse order seconds ago is between first and second
        let oracle = initialize_for_testing(5, i32::neg_from(5), 5);
        grow_for_testing(&mut oracle, 2);
        update_for_testing(&mut oracle, 4, i32::from(1), 2);
        update_for_testing(&mut oracle, 3, i32::neg_from(5), 4);
        oracle.time = oracle.time + 7;
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, vector::singleton(9));
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(19)) &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 442367076997220002502386989661298674892,
            0
        );

        //can fetch multiple observations
        let oracle = initialize_for_testing(5, i32::from(2), 1 << 15);
        grow_for_testing(&mut oracle, 4);
        update_for_testing(&mut oracle, 13, i32::from(6), 1 << 12);
        oracle.time = oracle.time + 5;
        let seconds_agos = vector<u64> [0, 3, 8, 13, 15, 18];
        let (tick_cumulatives, seconds_per_liquidity_cumulatives) = observe_for_testing(&oracle, seconds_agos);
        assert!(vector::length(&tick_cumulatives) == 6 && vector::length(&seconds_per_liquidity_cumulatives) == 6, 0);
        assert!(
            i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::from(56)) &&
            i64::eq(*vector::borrow(&tick_cumulatives, 1), i64::from(38)) &&
            i64::eq(*vector::borrow(&tick_cumulatives, 2), i64::from(20)) &&
            i64::eq(*vector::borrow(&tick_cumulatives, 3), i64::from(10)) &&
            i64::eq(*vector::borrow(&tick_cumulatives, 4), i64::from(6)) &&
            i64::eq(*vector::borrow(&tick_cumulatives, 5), i64::from(0)),
            0
        );
        assert!(
            *vector::borrow(&seconds_per_liquidity_cumulatives, 0) == 550383467004691728624232610897330176 &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 1) == 301153217795020002454768787094765568 &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 2) == 103845937170696552570609926584401920 &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 3) == 51922968585348276285304963292200960 &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 4) == 31153781151208965771182977975320576 &&
            *vector::borrow(&seconds_per_liquidity_cumulatives, 5) == 0,
            0
        );
    }
}