# lib/bench/scenarios.rb
module Bench
  module Scenarios
    Scenario = Struct.new(:name, :params, :expected_total, keyword_init: true)

    DEFINITIONS = {
      "baseline" => {
        # duration only applies when jobs == 0 (pure idle-polling measurement)
        defaults: { "jobs" => 20_000, "rate" => 500, "work_ms" => 50, "duration" => 60 },
        expected: ->(p) { p["jobs"] }
      },
      "sprawl" => {
        defaults: { "seeds" => 100, "fanout" => 50, "depth" => 2, "work_ms" => 10 },
        expected: ->(p) { p["seeds"] * (0..p["depth"]).sum { |i| p["fanout"]**i } }
      }
    }.freeze

    def self.build(name, raw_params)
      defn = DEFINITIONS[name] or raise ArgumentError,
        "unknown scenario #{name.inspect} (available: #{DEFINITIONS.keys.join(", ")})"
      unknown = raw_params.keys - defn[:defaults].keys
      raise ArgumentError, "unknown params for #{name}: #{unknown.join(", ")}" if unknown.any?

      params = defn[:defaults].merge(raw_params.transform_values(&:to_i))
      Scenario.new(name: name, params: params, expected_total: defn[:expected].call(params))
    end

    def self.names = DEFINITIONS.keys
  end
end
