require "bundler"
require "bundler/gem_tasks"
Bundler.setup

Bundler::GemHelper.install_tasks
Dir.glob("lib/tasks/**/*.rake").each do |rakefile|
  load rakefile
end

task :ci => ['uri_service:ci']
task :default => :ci