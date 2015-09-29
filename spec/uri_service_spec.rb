require 'spec_helper'

describe UriService do
  
  it "should be a module" do
    expect(UriService).to be_a Module
  end
  
  describe "::version" do
    it "should return the version" do
      expect(UriService::version).to eq(subject::VERSION)
    end
  end
  
end
