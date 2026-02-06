# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

# Load all task files from lib/tasks
Dir[File.expand_path("lib/tasks/**/*.rake", __dir__)].each { |f| load f }
