source "https://rubygems.org"

gem "railties", "~> 8.0.0"
gem "activerecord", "~> 8.0.0"
gem "activejob", "~> 8.0.0"
gem "trilogy"

case (sq_source = ENV.fetch("SOLID_QUEUE_SOURCE", "upstream"))
when "upstream"
  gem "solid_queue"
when /\Aupstream@(.+)\z/
  gem "solid_queue", Regexp.last_match(1)
when /\Apath:(.+)\z/
  gem "solid_queue", path: File.expand_path(Regexp.last_match(1))
else
  raise "Unknown SOLID_QUEUE_SOURCE: #{sq_source.inspect}"
end
