#
# Author:: Sander Botman (<sbotman@schubergphilis.com>)
# Copyright:: Copyright (c) 2013 Sander Botman.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'

class Chef
  class Knife

    class CookbookGithubList < Knife

      deps do
        require 'chef/mixin/shell_out'
      end

      banner "knife cookbook github list [COOKBOOK] (options)"
      category "cookbook"

      option :fields,
             :long => "--fields 'NAME, NAME'",
             :description => "The fields to output, comma-separated"

      option :noheader,
             :long => "--noheader",
             :description => "Removes header from output",
             :boolean => true

      option :all,
             :short => "-a",
             :long => "--all",
             :description => "Get all cookbooks from github.",
             :boolean => true

      option :mismatch,
             :short => "-m",
             :long => "--mismatch",
             :description => "Only show cookbooks where versions mismatch",
             :boolean => true

      option :github_organizations,
             :long => "--github-org ORG:ORG",
             :description => "Lookup chef cookbooks in this colon-separated list of organizations",
             :proc => lambda { |o| o.split(":") }

      option :github_api_version,
             :long => "--github-api_ver VERSION",
             :description => "Version number of the API (default is: v3)"

      option :github_url,
             :long => "--github-url URL",
             :description => "URL of the github enterprise appliance"

      option :github_no_ssl_verify,
             :long => "--github-no_ssl_verify",
             :description => "Disable ssl verify on the url if https is used.",
             :boolean => true

      option :github_cache,
             :long => "--github-cache MIN",
             :description => "Max life-time for local cache file in minutes."

      def run
        extend Chef::Mixin::ShellOut

        config[:github_url]           ? @github_url = config[:github_url]                     : @github_url = Chef::Config[:github_url]
        config[:github_api_version]   ? @github_api_version = config[:github_api_version]     : @github_api_version = Chef::Config[:github_api_version] || "v3"
        config[:github_no_ssl_verify] ? @github_no_ssl_verify = config[:github_no_ssl_verify] : @github_no_ssl_verify = Chef::Config[:github_no_ssl_verify] || false
        config[:github_organizations] ? @github_organizations = config[:github_organizations] : @github_organizations = Chef::Config[:github_organizations]
        config[:github_cache]         ? @github_cache = config[:github_cache] 		      : @github_cache = Chef::Config[:github_cache] || 900

        display_debug_info!



        # Gather all repo information from github 
        get_all_repos = get_all_repos(@github_organizations.reverse)


        # Get all chef cookbooks and versions (hopefully chef does the error handeling)
        cb_and_ver = rest.get_rest("/cookbooks?num_version=1")


        # Filter all repo information based on the tags that we can find
        all_repos = {}
        if config[:all]
          get_all_repos.each { |k,v|
            cookbook = k
            cb_and_ver[k].nil? || cb_and_ver[k]['versions'].nil? ? version = "" : version = cb_and_ver[k]['versions'][0]['version']
            ssh_url = v['ssh_url']
            gh_tag  = v['latest_tag']
            all_repos[cookbook] = { 'name' => cookbook, 'latest_cb_tag' => version, 'ssh_url' => ssh_url, 'latest_gh_tag' => gh_tag }
          } 
        else
          cb_and_ver.each { |k,v|
            cookbook = k
            version  = v['versions'][0]['version']
            get_all_repos[k].nil? || get_all_repos[k]['ssh_url'].nil? ? ssh_url = ui.color("ERROR: Cannot find cookbook!", :red) : ssh_url = get_all_repos[k]['ssh_url']
            get_all_repos[k].nil? || get_all_repos[k]['latest_tag'].nil? ? gh_tag = ui.color("ERROR: No tags!", :red) : gh_tag = get_all_repos[k]['latest_tag']
            all_repos[cookbook] = { 'name' => cookbook, 'latest_cb_tag' => version, 'ssh_url' => ssh_url, 'latest_gh_tag' => gh_tag } 
          }
        end
 

        # Filter only on the cookbook name if its given on the command line
        @cookbook_name = name_args.first unless name_args.empty?
        if @cookbook_name
          repos = all_repos.select { |k,v| v["name"] == @cookbook_name }
        else
          repos = all_repos 
        end


        # Displaying information based on the fields and repos
        if config[:fields]
          object_list = []
          config[:fields].split(',').each { |n| object_list << ui.color(("#{n}").strip, :bold) }
        else
          object_list = [
            ui.color('Cookbook', :bold),
            ui.color('Tag', :bold),
            ui.color('Github', :bold),
            ui.color('Tag', :bold)
          ]
        end

        columns = object_list.count
        object_list = [] if config[:noheader]

        repos.each do |k,r|
          if config[:fields]
             config[:fields].downcase.split(',').each { |n| object_list << ((r[("#{n}").strip]).to_s || 'n/a') }
          else
            next if config[:mismatch] && (r['latest_gh_tag'] == r['latest_cb_tag'])
            r['latest_gh_tag'] == r['latest_cb_tag'] ? color = :white : color = :yellow
            color = :white if config[:all]
 
            object_list << ui.color((r['name'] || 'n/a'), color)
            object_list << ui.color((r['latest_cb_tag'] || 'n/a'), color)
            object_list << ui.color((r['ssh_url'] || 'n/a'), color)
            object_list << ui.color((r['latest_gh_tag'] || 'n/a'), color)
          end
        end

        puts ui.list(object_list, :uneven_columns_across, columns)

      end
    


      def get_all_repos(orgs)
        # Parse every org and merge all into one hash
        repos = {}
        orgs.each do |org|
          get_repos(org).each { |repo| name = repo['name'] ; repos["#{name}"] = repo } 
        end
        repos
      end



      def get_repos(org)
        dns_name  = get_dns_name(@github_url)
        file_cache = "#{ENV['HOME']}/.chef/.#{dns_name.downcase}_#{org.downcase}.cache" 
        if File.exists?(file_cache)
          Chef::Log.debug("#{org} cache is created: " + (Time.now - File.ctime(file_cache)).to_i.to_s  + " seconds ago.")
          if Time.now - File.ctime(file_cache) > @github_cache
            # update cache file
            create_cache_file(file_cache, org)
          end
        else
          create_cache_file(file_cache, org)
        end
        # use cache files
        JSON.parse(File.read(file_cache))
      end

      def create_cache_file(file_cache, org)
        Chef::Log.debug("Updating the cache file: #{file_cache}")
        result = get_repos_github(org)
        File.open(file_cache, 'w') { |file| file.write(JSON.pretty_generate(result)) }
      end


 
      def get_repos_github(org)
        # Get all repo's for the org from github
        arr  = []
        page = 1
        url  = @github_url + "/api/" + @github_api_version + "/orgs/" + org + "/repos" 
        while true
          params = { 'page' => page }
          result = send_request(url, params)
          break if result.nil? || result.count < 1
          result.each { |key|
            if key['tags_url']
              tags = get_tags(key)
              key['tags'] = tags unless tags.nil? || tags.empty?
              key['latest_tag'] = tags.first['name'] unless tags.nil? || tags.empty?
              arr << key
            else 
              arr << key 
            end
          }
          page = page + 1
        end
        arr
      end


      def get_tags(repo)
        tags = send_request(repo['tags_url'])
        tags
      end


      def get_dns_name(url)
        dns = url.downcase.gsub("http://","") if url.downcase.start_with?("http://")
        dns = url.downcase.gsub("https://","") if url.downcase.start_with?("https://")
        dns
      end


      def send_request(url, params = {})
        params['response'] = 'json'

        params_arr = []
        params.sort.each { |elem|
          params_arr << elem[0].to_s + '=' + CGI.escape(elem[1].to_s).gsub('+', '%20').gsub(' ','%20')
        }
        data = params_arr.join('&')

        if url.nil? || url.empty?
          puts "Error: Please specify a valid Github URL."
          exit 1
        end

        github_url = "#{url}?#{data}" 
        # Chef::Log.debug("URL: #{github_url}")

        uri = URI.parse(github_url)
        req_body = Net::HTTP::Get.new(uri.request_uri)
        request = Chef::REST::RESTRequest.new("GET", uri, req_body, headers={})
      
        response = request.call
      
        if !response.is_a?(Net::HTTPOK) then
          puts "Error #{response.code}: #{response.message}"
          puts JSON.pretty_generate(JSON.parse(response.body))
          puts "URL: #{url}"
          exit 1
        end
        json = JSON.parse(response.body)
      end

      def display_debug_info!
        Chef::Log.debug("github_url: " + @github_url)
        Chef::Log.debug("github_ssl: false") if @github_no_ssl_verify
        Chef::Log.debug("github_api: " + @github_api_version)
        Chef::Log.debug("github_org: " + @github_organizations.to_s)
        Chef::Log.debug("github_cache: " + @github_cache.to_s)
      end

    end
  end
end
