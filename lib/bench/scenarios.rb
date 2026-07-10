# lib/bench/scenarios.rb
module Bench
  module Scenarios
    Scenario = Struct.new(:name, :params, :expected_total, keyword_init: true)

    DEFINITIONS = {
      "baseline" => {
        # duration only applies when jobs == 0 (pure idle-polling measurement)
        defaults: { "jobs" => 20_000, "rate" => 500, "work_ms" => 50, "duration" => 60 },
        expected: ->(p) { p["jobs"] },
        # rate 0 would stall the driver's pacing loop; irrelevant when jobs == 0 (idle variant)
        validate: ->(p) do
          if p["jobs"] > 0 && p["rate"] < 1
            raise ArgumentError, "baseline rate must be >= 1 (got #{p["rate"]})"
          end
        end
      },
      "baseline_limited" => {
        defaults: { "jobs" => 1_000, "rate" => 500, "work_ms" => 50 },
        expected: ->(p) { p["jobs"] },
        validate: ->(p) do
          if p["jobs"] > 0 && p["rate"] < 1
            raise ArgumentError, "baseline_limited rate must be >= 1 (got #{p["rate"]})"
          end
        end
      },
      "sprawl" => {
        defaults: { "seeds" => 100, "fanout" => 50, "depth" => 2, "work_ms" => 10 },
        expected: ->(p) { p["seeds"] * (0..p["depth"]).sum { |i| p["fanout"]**i } }
      },
      "sprawl_limited" => {
        defaults: { "seeds" => 100, "fanout" => 50, "depth" => 2, "work_ms" => 10 },
        expected: ->(p) { p["seeds"] * (0..p["depth"]).sum { |i| p["fanout"]**i } }
      }
    }.freeze

    def self.build(name, raw_params)
      defn = DEFINITIONS[name] or raise ArgumentError,
        "unknown scenario #{name.inspect} (available: #{DEFINITIONS.keys.join(", ")})"
      unknown = raw_params.keys - defn[:defaults].keys
      raise ArgumentError, "unknown params for #{name}: #{unknown.join(", ")}" if unknown.any?

      typed = raw_params.to_h do |k, v|
        [k, Integer(v)]
      rescue ArgumentError, TypeError
        raise ArgumentError, "invalid value for #{name} param #{k}: #{v.inspect} (expected integer)"
      end
      params = defn[:defaults].merge(typed)
      defn[:validate]&.call(params)
      Scenario.new(name: name, params: params, expected_total: defn[:expected].call(params))
    end

    def self.names = DEFINITIONS.keys
  end
end
