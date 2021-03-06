require 'thor'

require_relative 'aws_helper'
require_relative 'launch_helper'

module OpenShift
  module Ops
    class AwsCommand < Thor
      # WARNING: we do not currently support environments with hyphens in the name
      SUPPORTED_ENVS = %w(prod stg int ops twiest gshipley kint test jhonce amint tdint lint jdetiber)

      option :type, :required => true, :enum => LaunchHelper.get_aws_host_types,
             :desc => 'The host type of the new instances.'
      option :env, :required => true, :aliases => '-e', :enum => SUPPORTED_ENVS,
             :desc => 'The environment of the new instances.'
      option :count, :default => 1, :aliases => '-c', :type => :numeric,
             :desc => 'The number of instances to create'
      option :tag, :type => :array,
             :desc => 'The tag(s) to add to the new instances. Allowed characters are letters, numbers, and hyphens.'
      desc "launch", "Launches instances."
      def launch()
        AwsHelper.check_creds()

        # Expand all of the instance names so that we have a complete array
        names = []
        options[:count].times { names << "#{options[:env]}-#{options[:type]}-#{SecureRandom.hex(5)}" }

        ah = AnsibleHelper.for_aws()

        # AWS specific configs
        ah.extra_vars['oo_new_inst_names'] = names
        ah.extra_vars['oo_new_inst_tags'] = options[:tag]
        ah.extra_vars['oo_env'] = options[:env]

        # Add a created by tag
        ah.extra_vars['oo_new_inst_tags'] = {} if ah.extra_vars['oo_new_inst_tags'].nil?

        ah.extra_vars['oo_new_inst_tags']['created-by'] = ENV['USER']
        ah.extra_vars['oo_new_inst_tags'].merge!(AwsHelper.generate_env_tag(options[:env]))
        ah.extra_vars['oo_new_inst_tags'].merge!(AwsHelper.generate_host_type_tag(options[:type]))
        ah.extra_vars['oo_new_inst_tags'].merge!(AwsHelper.generate_env_host_type_tag(options[:env], options[:type]))

        puts
        puts "Creating #{options[:count]} #{options[:type]} instance(s) in AWS..."

        # Make sure we're completely up to date before launching
        clear_cache()
        ah.run_playbook("playbooks/aws/#{options[:type]}/launch.yml")
      ensure
        # This is so that if we a config right after a launch, the newly launched instances will be
        # in the list.
        clear_cache()
      end

      desc "clear-cache", 'Clear the inventory cache'
      def clear_cache()
        print "Clearing inventory cache... "
        AwsHelper.clear_inventory_cache()
        puts "Done."
      end

      option :name, :required => false, :type => :string,
             :desc => 'The name of the instance to configure.'
      option :env, :required => false, :aliases => '-e', :enum => SUPPORTED_ENVS,
             :desc => 'The environment of the new instances.'
      option :type, :required => false, :enum => LaunchHelper.get_aws_host_types,
             :desc => 'The type of the instances to configure.'
      desc "config", 'Configures instances.'
      def config()
        ah = AnsibleHelper.for_aws()

        abort 'Error: you can\'t specify both --name and --type' unless options[:type].nil? || options[:name].nil?

        abort 'Error: you can\'t specify both --name and --env' unless options[:env].nil? || options[:name].nil?

        host_type = nil
        if options[:name]
          details = AwsHelper.get_host_details(options[:name])
          ah.extra_vars['oo_host_group_exp'] = details['ec2_public_dns_name']
          ah.extra_vars['oo_env'] = details['ec2_tag_environment']
          host_type = details['ec2_tag_host-type']
        elsif options[:type] && options[:env]
          oo_env_host_type_tag = AwsHelper.generate_env_host_type_tag_name(options[:env], options[:type])
          ah.extra_vars['oo_host_group_exp'] = "groups['#{oo_env_host_type_tag}']"
          ah.extra_vars['oo_env'] = options[:env]
          host_type = options[:type]
        else
          abort 'Error: you need to specify either --name or (--type and --env)'
        end

        puts
        puts "Configuring #{options[:type]} instance(s) in AWS..."

        ah.run_playbook("playbooks/aws/#{host_type}/config.yml")
      end

      option :env, :required => false, :aliases => '-e', :enum => SUPPORTED_ENVS,
             :desc => 'The environment to list.'
      desc "list", "Lists instances."
      def list()
        AwsHelper.check_creds()
        hosts = AwsHelper.get_hosts()

        hosts.delete_if { |h| h.env != options[:env] } unless options[:env].nil?

        fmt_str = "%34s %5s %8s %17s %7s"

        puts
        puts fmt_str % ['Name','Env', 'State', 'IP Address', 'Created By']
        puts fmt_str % ['----','---', '-----', '----------', '----------']
        hosts.each { |h| puts fmt_str % [h.name, h.env, h.state, h.public_ip, h.created_by ] }
        puts
      end

      desc "ssh", "Ssh to an instance"
      def ssh(*ssh_ops, host)
        if host =~ /^([\w\d_.\-]+)@([\w\d\-_.]+)/
          user = $1
          host = $2
        end

        details = AwsHelper.get_host_details(host)
        abort "\nError: Instance [#{host}] is not RUNNING\n\n" unless details['ec2_state'] == 'running'

        cmd = "ssh #{ssh_ops.join(' ')}"

        if user.nil?
          cmd += " "
        else
          cmd += " #{user}@"
        end

        cmd += "#{details['ec2_ip_address']}"

        exec(cmd)
      end

      desc 'types', 'Displays instance types'
      def types()
        puts
        puts "Available Host Types"
        puts "--------------------"
        LaunchHelper.get_aws_host_types.each { |t| puts "  #{t}" }
        puts
      end
    end
  end
end
