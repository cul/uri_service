require "bundler/gem_tasks"

Dir.glob("lib/tasks/**/*.rake").each do |rakefile|
  load rakefile
end

task ci: 'uri_service:ci'
task default: 'ci'