require 'spec_helper'
require 'yaml'
require 'uri_service/client'

describe UriService, type: :integration do

  describe "::init" do
    it "doesn't raise an error upon init method call when valid connection opts are given" do
      UriService::init(YAML.load(fixture('uri_service_test_config.yml'))['sqlite'])
    end
    
    it "raises an error upon init method call when invalid connection opts are given (to verify that init is actually doing something)" do
      expect{ UriService::init({}) }.to raise_error(UriService::InvalidOptsError)
    end
    
    it "can be called multiple times in a row (to reinitialize) without raising any errors" do
      UriService::init(YAML.load(fixture('uri_service_test_config.yml'))['sqlite'])
      UriService::init(YAML.load(fixture('uri_service_test_config.yml'))['sqlite'])
    end
  end
  
  describe "::client" do
    it "returns an instance of UriService::Client after ::init is called with valid opts, and this client should be properly connected" do
      UriService::init(YAML.load(fixture('uri_service_test_config.yml'))['sqlite'])
      expect(UriService.client).to be_instance_of(UriService::Client)
      expect(UriService.client.connected?).to eq(true)
    end
  end

end
