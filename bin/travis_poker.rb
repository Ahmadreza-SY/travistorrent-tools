require 'travis'
require 'net/http'
require 'csv'
require 'open-uri'

# Reads in a CSV as first argument. CSV structure login,project,.. as input, and outputs
# login,project,...,num_travisbuilds

@input_csv = ARGV[0]
ANSI_COLOR_CODES_REGEX = /\x1B\[([0-9]{1,3}((;[0-9]{1,2})?){1,2})?[mGK]/
PROGRESS_LOGS_REGEX = /Progress \(\d*\):.*[\n\r]*/
MAVEN_TEST_REGEX = /Running (?<test_name>([A-Za-z]{1}[A-Za-z\d_]*\.)+[A-Za-z][A-Za-z\d_]*)(.*?)Tests run: (?<total_tests>\d*), Failures: (?<failed_tests>\d*), Errors: (?<error_tests>\d*), Skipped: (?<skipped_tests>\d*), Time elapsed: (?<test_duration>[+-]?([0-9]*[.])?[0-9]+)/m

def determine_log_type(repository)  
  last_build_number = repository.last_build.number.to_i
  repo_id = repository.id
  url = "https://api.travis-ci.org/builds?after_number=#{last_build_number}&repository_id=#{repo_id}"
  resp = open(url, 'Content-Type' => 'application/json', 'Accept' => 'application/vnd.travis-ci.2+json')
  builds = JSON.parse(resp.read)
  builds['builds'].each { |build_json|
    build = repository.build(build_json['number'].to_i)
    puts "Investigating build #{build.id} with number #{build.number} at #{repository.slug}"
    build.jobs.each { |job|
      unless job.nil?
        next if (job.log.nil? || job.log.body.nil?)
        log = job.log.body
        log = log.gsub(ANSI_COLOR_CODES_REGEX, '').gsub(PROGRESS_LOGS_REGEX, '')
        if log.scan(MAVEN_TEST_REGEX).size >= 1
          puts "Found maven logs at #{repository.slug}"
          return 'maven'
        end
      end
    }
  }
  return 'plain'
end

def travis_builds_for_project(repo, wait_in_s)
  begin
    if(wait_in_s > 128)
      STDERR.puts "We can't wait forever for #{repo}"
      return 0
    elsif(wait_in_s > 1)
      sleep wait_in_s
    end
    repository = Travis::Repository.find(repo)
    last_build = repository.last_build
    if last_build.nil?
      return 0, 'plain'
    end
    log_type = determine_log_type(repository)
    return last_build.number, log_type
  rescue Exception => e
    STDERR.puts "Exception at #{repo}"
    STDERR.puts e.message
    if e.message.start_with?("429")
      STDERR.puts "Encountered API restriction: next call, sleeping for #{wait_in_s*2}"
      return travis_builds_for_project repo, wait_in_s*2
    end
    if e.message.empty?
      STDERR.puts "Empty exception, sleeping for #{wait_in_s*2}"
      return travis_builds_for_project repo, wait_in_s*2
    end
    return 0, 'plain'
  end
end


def analyze_projects_on_travis
  i = 0
  File.open("#{@input_csv}-annotated.csv", 'w') { |file|
    CSV.foreach(@input_csv, :headers => true) do |row|
      curRow = row
      builds, log_type = travis_builds_for_project("#{row[0]}/#{row[1]}", 1)
      curRow << builds.to_s
      curRow << log_type
      file.write(curRow.to_csv)
      i += 1
      file.flush if i%50 == 0
    end
  }

end

analyze_projects_on_travis