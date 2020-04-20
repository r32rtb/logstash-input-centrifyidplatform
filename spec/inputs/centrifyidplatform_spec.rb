# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/inputs/centrifyidplatform"

describe LogStash::Inputs::centrifyidplatform do

  it_behaves_like "an interruptible input plugin" do
    let(:config) { { "interval" => 600 } }
  end

end
