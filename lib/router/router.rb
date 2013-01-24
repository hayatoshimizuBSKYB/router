# Copyright (c) 2009-2011 VMware, Inc.
class Router

  VERSION = 0.98

  class << self
    attr_reader   :log, :notfound_redirect
    attr_accessor :server, :local_server, :timestamp, :pid_file
    attr_accessor :inet, :port

    def version
      VERSION
    end

    def stop
      log.info 'Signal caught, shutting down..'

      server.stop if server
      local_server.stop if local_server

      NATS.stop { EM.stop }
      pid_file.unlink()
      log.info 'Bye'
    end

    def config(config)
      @droplets = {}
      VCAP::Logging.setup_from_config(config['logging'] || {})
      @log = VCAP::Logging.logger('router')
      if config['404_redirect']
        @notfound_redirect = "HTTP/1.1 302 Not Found\r\nConnection: close\r\nLocation: #{config['404_redirect']}\r\n\r\n".freeze
        log.info "Registered 404 redirect at #{config['404_redirect']}"
      end

      @expose_all_apps = config['status']['expose_all_apps'] if config['status']

      @enable_nonprod_apps = config['enable_nonprod_apps'] || false
      if @enable_nonprod_apps
        @flush_apps_interval = config['flush_apps_interval'] || 30
        @active_apps = Set.new
        @flushing_apps = Set.new
        @flushing = false
      end
    end

    def setup_listeners
      NATS.subscribe('router.register') { |msg|
        msg_hash = Yajl::Parser.parse(msg, :symbolize_keys => true)
        return unless uris = msg_hash[:uris]
        uris.each { |uri| register_droplet(uri, msg_hash[:host], msg_hash[:port],
                                           msg_hash[:tags], msg_hash[:app], msg_hash[:private_instance_id]) }
      }
      NATS.subscribe('router.unregister') { |msg|
        msg_hash = Yajl::Parser.parse(msg, :symbolize_keys => true)
        return unless uris = msg_hash[:uris]
        uris.each { |uri| unregister_droplet(uri, msg_hash[:host], msg_hash[:port]) }
      }
    end

    def setup_sweepers
      @rps_timestamp = Time.now
      @current_num_requests = 0
      EM.add_periodic_timer(RPS_SWEEPER) { calc_rps }
      EM.add_periodic_timer(CHECK_SWEEPER) {
        check_registered_urls
      }
      if @enable_nonprod_apps
        EM.add_periodic_timer(@flush_apps_interval) do
          flush_active_apps
        end
      end
    end

    def calc_rps
      # Update our timestamp and calculate delta for reqs/sec
      now = Time.now
      delta = (now - @rps_timestamp).to_f
      @rps_timestamp = now

      # Now calculate Requests/sec
      new_num_requests = VCAP::Component.varz[:requests]
      VCAP::Component.varz[:requests_per_sec] = ((new_num_requests - @current_num_requests)/delta).to_i
      @current_num_requests = new_num_requests

      # Go ahead and calculate rates for all backends here.
      apps = []
      @droplets.each_pair do |url, instances|
        total_requests = 0
        clients_hash = Hash.new(0)
        instances.each do |droplet|
          total_requests += droplet[:requests]
          droplet[:requests] = 0
          droplet[:clients].each_pair { |ip,req| clients_hash[ip] += req }
          droplet[:clients] = Hash.new(0) # Wipe these per sweep
        end

        # Grab top 5 clients responsible for the traffic
        clients, clients_array = [], clients_hash.sort { |a,b| b[1]<=>a[1] } [0,4]
        clients_array.each { |c| clients << { :ip => c[0], :rps => (c[1]/delta).to_i } }

        # Add in clients if they exist and the entry if rps != 0
        if (rps = (total_requests/delta).to_i) > 0
          entry = { :url => url, :rps => rps }
          entry[:clients] = clients unless clients.empty?
          apps << entry unless entry[:rps] == 0
        end
      end

      top = apps.sort { |a,b| b[:rps]<=>a[:rps] }
      VCAP::Component.varz[:top_app_requests]  = top if @expose_all_apps
      VCAP::Component.varz[:top10_app_requests]  = top[0,9]
      #log.debug "Calculated all request rates in  #{Time.now - now} secs."
    end

    def check_registered_urls
      start = Time.now

      # If NATS is reconnecting, let's be optimistic and assume
      # the apps are there instead of actively pruning.
      if NATS.client.reconnecting?
        log.info "Suppressing checks on registered URLS while reconnecting to mbus."
        @droplets.each_pair do |url, instances|
          instances.each { |droplet| droplet[:timestamp] = start }
        end
        return
      end

      to_drop = []
      @droplets.each_pair do |url, instances|
        instances.each do |droplet|
          to_drop << droplet if ((start - droplet[:timestamp]) > MAX_AGE_STALE)
        end
      end
      log.debug "Checked all registered URLS in #{Time.now - start} secs."
      to_drop.each { |droplet| unregister_droplet(droplet[:url], droplet[:host], droplet[:port]) }
    end

    def get_session_cookie(droplet)
      droplet[:session] || ""
    end

    def lookup_droplet(url)
      @droplets[url.downcase]
    end

    def register_droplet(url, host, port, tags, app_id, session=nil)
      return unless host && port
      url.downcase!
      tags ||= {}

      droplets = @droplets[url] || []
      # Skip the ones we already know about..
      droplets.each { |droplet|
        # If we already now about them just update the timestamp..
        if(droplet[:host] == host && droplet[:port] == port)
          droplet[:timestamp] = Time.now
          return
        end
      }
      tags.delete_if { |key, value| key.nil? || value.nil? }
      droplet = {
        :app => app_id,
        :session => session,
        :host => host,
        :port => port,
        :clients => Hash.new(0),
        :url => url,
        :timestamp => Time.now,
        :requests => 0,
        :tags => tags
      }
      add_tag_metrics(tags)
      droplets << droplet
      @droplets[url] = droplets
      VCAP::Component.varz[:urls] = @droplets.size
      VCAP::Component.varz[:droplets] += 1
      log.info "Registering #{url} at #{host}:#{port}"
      log.info "#{droplets.size} servers available for #{url}"
    end

    def unregister_droplet(url, host, port)
      log.info "Unregistering #{url} for host #{host}:#{port}"
      url.downcase!
      droplets = @droplets[url] || []
      dsize = droplets.size
      droplets.delete_if { |d| d[:host] == host && d[:port] == port}
      @droplets.delete(url) if droplets.empty?
      VCAP::Component.varz[:urls] = @droplets.size
      VCAP::Component.varz[:droplets] -= 1 unless (dsize == droplets.size)
      log.info "#{droplets.size} servers available for #{url}"
    end

    def add_tag_metrics(tags)
      tags.each do |key, value|
        key_metrics = VCAP::Component.varz[:tags][key] ||= {}
        key_metrics[value] ||= {
          :requests => 0,
          :latency => VCAP::RollingMetric.new(60),
          :responses_2xx => 0,
          :responses_3xx => 0,
          :responses_4xx => 0,
          :responses_5xx => 0,
          :responses_xxx => 0
        }
      end
    end

    def add_active_app(app_id)
      return unless @enable_nonprod_apps

      @active_apps << app_id
    end

    def flush_active_apps
      return unless @enable_nonprod_apps

      return if @flushing
      @flushing = true

      @active_apps, @flushing_apps = @flushing_apps, @active_apps
      @active_apps.clear

      EM.defer do
        msg = Yajl::Encoder.encode(@flushing_apps.to_a)
        zmsg = Zlib::Deflate.deflate(msg)

        log.info("Flushing active apps, app size: #{@flushing_apps.size}, msg size: #{zmsg.size}")
        EM.next_tick { NATS.publish('router.active_apps', zmsg) }

        @flushing = false
      end

    end
  end
end
