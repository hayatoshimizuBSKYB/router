# Copyright (c) 2009-2011 VMware, Inc.
require File.dirname(__FILE__) + '/spec_helper'
require "base64"

describe 'Router Functional Tests' do

  include Functional

  ROUTER_V1_DROPLET = { :url => 'router_test.vcap.me', :host => '127.0.0.1', :port => 12345 }
  ROUTER_V1_SESSION = "zXiJv9VIyWW7kqrcqYUkzj+UEkC4UUHGaYX9fCpDMm2szLfOpt+aeRZMK7kfkpET+PDhvfKRP/M="

  before :each do
    nats_dir = Dir.mktmpdir('router-test-nats')
    nats_pid = File.join(nats_dir, 'nats-server.pid')
    nats_port = VCAP::grab_ephemeral_port
    @nats_server = NatsServer.new(nats_pid, nats_port, nats_dir)
    @nats_server.start

    router_dir = Dir.mktmpdir('router-test-router')
    @router_server = RouterServer.new(@nats_server.uri, router_dir)
    @router_server.start
    @router_server.is_running?.should be_true
  end

  after :each do
    @router_server.stop
    @router_server.is_running?.should be_false

    @nats_server.stop
    @nats_server.ready?.should be_false
  end

  it 'should respond to a discover message properly' do
    reply = json_request(@nats_server.uri, 'vcap.component.discover')
    reply.should_not be_nil
    reply[:type].should =~ /router/i
    reply.should have_key :uuid
    reply.should have_key :host
    reply.should have_key :start
    reply.should have_key :uptime
  end

  it 'should have proper http endpoints (/healthz, /varz)' do
    reply = json_request(@nats_server.uri, 'vcap.component.discover')
    reply.should_not be_nil

    credentials = reply[:credentials]
    credentials.should_not be_nil

    host, port = reply[:host].split(":")

    healthz_req = Net::HTTP::Get.new("/healthz")
    healthz_req.basic_auth *credentials
    healthz_resp = Net::HTTP.new(host, port).start { |http| http.request(healthz_req) }
    healthz_resp.body.should =~ /ok/i

    varz = get_varz()
    varz[:requests].should be_a_kind_of(Integer)
    varz[:bad_requests].should be_a_kind_of(Integer)
    varz[:type].should =~ /router/i
  end

  it 'should properly register an application endpoint' do
    # setup the "app"
    app = TestApp.new('router_test.vcap.me')
    dea = DummyDea.new(@nats_server.uri, '1234')
    dea.register_app(app)
    app.verify_registered
  end

  it 'should properly unregister an application endpoint' do
    # setup the "app"
    app = TestApp.new('router_test.vcap.me')
    dea = DummyDea.new(@nats_server.uri, '1234')
    dea.register_app(app)
    app.verify_registered
    dea.unregister_app(app)
    app.verify_unregistered
  end

  it 'should properly publish active applications set' do
    # setup the "app"
    app1 = TestApp.new('router_test1.vcap.me')
    app2 = TestApp.new('router_test2.vcap.me')
    dea = DummyDea.new(@nats_server.uri, '1234')
    dea.register_app(app1)
    dea.register_app(app2)
    app1.verify_registered
    app2.verify_registered
    original_apps_set = Set.new([app1.id, app2.id])
    received_apps_set = nil

    NATS.start(:uri => @nats_server.uri) do
      NATS.subscribe('router.active_apps') do |msg|
        apps_list = Yajl::Parser.parse(Zlib::Inflate.inflate(msg))
        received_apps_set = Set.new(apps_list)
        NATS.stop
      end

      EM.add_timer(60) { NATS.stop } # 60 secs timeout
    end

    original_apps_set.should == received_apps_set
  end

  it 'should properly exit when NATS fails to reconnect' do
    @nats_server.stop
    @nats_server.ready?.should be_false
    sleep(0.5)
    @router_server.is_running?.should be_false
  end

  it 'should not start with nats not running' do
    @nats_server.stop
    @nats_server.ready?.should be_false
    @router_server.stop
    @router_server.is_running?.should be_false

    @router_server.start
    sleep(0.5)
    @router_server.is_running?.should be_false
  end

  # Encodes _data_ as json, decodes reply as json
  def json_request(uri, subj, data=nil, timeout=1)
    reply = nil
    data_enc = data ? Yajl::Encoder.encode(data) : nil
    NATS.start(:uri => uri) do
      NATS.request(subj, data_enc) do |msg|
        reply = JSON.parse(msg, :symbolize_keys => true)
        NATS.stop
      end
      EM.add_timer(timeout) { NATS.stop }
    end

    reply
  end

  def get_varz
    reply = json_request(@nats_server.uri, 'vcap.component.discover')
    reply.should_not be_nil

    credentials = reply[:credentials]
    credentials.should_not be_nil

    host, port = reply[:host].split(":")

    varz_req = Net::HTTP::Get.new("/varz")
    varz_req.basic_auth *credentials
    varz_resp = Net::HTTP.new(host, port).start { |http| http.request(varz_req) }
    varz = JSON.parse(varz_resp.body, :symbolize_keys => true)
    varz
  end

end
