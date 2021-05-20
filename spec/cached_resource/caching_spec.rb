require 'spec_helper'

describe CachedResource do

  def read_from_cache(key)
    Thing.send(:cache_read, key)
  end

  before(:each) do
    class Thing < ActiveResource::Base
      self.site = "http://api.thing.com"
      cached_resource
    end

    @thing = {:thing => {:id => 1, :name => "Ada"}}
    @other_thing = {:thing => {:id => 1, :name => "Ari"}}
    @thing2 = {:thing => {:id => 2, :name => "Joe"}}
    @other_thing2 = {:thing => {:id => 2, :name => "Jeb"}}
    @thing3 = {:thing => {:id => 3, :name => "Stu"}}
    @string_thing = {:thing => {:id => "fded", :name => "Lev"}}
    @other_string_thing = {:thing => {:id => "fded", :name => "Lon"}}
    @date_thing = {:thing => {:id => 4, :created_at => Time.utc(2020).iso8601}}
    @thing_json = @thing.to_json
    @other_thing_json = @other_thing.to_json
    @string_thing_json = @string_thing.to_json
    @other_string_thing_json = @other_string_thing.to_json
    @date_thing_json = @date_thing.to_json
    @nil_thing = nil.to_json
  end

  after(:each) do
    Thing.cached_resource.cache.clear
    Object.send(:remove_const, :Thing)
  end

  describe "when enabled" do
    before(:each) do
      # it's on by default, but lets call the method
      # to make sure it works
      Thing.cached_resource.cache.clear
      Thing.cached_resource.on!

      ActiveResource::HttpMock.reset!
      ActiveResource::HttpMock.respond_to do |mock|
        mock.get "/things/1.json", {}, @thing_json
        mock.get "/things/1.json?foo=bar", {}, @thing_json
        mock.get "/things/fded.json", {}, @string_thing_json
        mock.get "/things.json?name=42", {}, @nil_thing, 404
        mock.get "/things/4.json", {}, @date_thing_json
      end
    end

    it "should cache a response" do
      result = Thing.find(1)

      read_from_cache("thing/1").should == result
    end

    it "should cache a nil response" do
      result = Thing.find(:all, :params => { :name => '42' })
      read_from_cache("thing/all/name/42").should == nil
    end

    it "should cache a response for a string primary key" do
      result = Thing.find("fded")
      read_from_cache("thing/fded").should == result
    end

    it "should cache without whitespace in keys" do
      result = Thing.find(1, :from => 'path', :params => { :foo => 'bar' })
      read_from_cache('thing/1/{:from=>"path",:params=>{:foo=>"bar"}}').should == result
    end

    it "should hash long parameters in cache key" do
      params = [1, {long_params: "l" * Thing::MAX_ARGUMENTS_CACHE_SIZE }]
      hash_params = Thing.send(:hash_string, params.join("/"))

      result = Thing.find(*params)
      Thing.cached_resource.cache.read("thing/#{hash_params}").should == result
    end

    it "should empty the cache when clear_cache is called" do
      result = Thing.find(1)
      Thing.clear_cache
      read_from_cache("thing/1").should == nil
    end

    it "should cache a response with the same persistence" do
      result1 = Thing.find(1)
      result1.persisted?.should be true
      result2 = Thing.find(1)
      result1.persisted?.should == result2.persisted?
    end

    it "should read a response when the request is made again" do
      # make a request
      Thing.find(1)
      # make the same request
      Thing.find(1)
      # only one request should have happened
      ActiveResource::HttpMock.requests.length.should == 1
    end

    it "should read a response when the request is made again for a string primary key" do
      # make a request
      Thing.find("fded")
      # make the same request
      Thing.find("fded")
      # only one request should have happened
      ActiveResource::HttpMock.requests.length.should == 1
    end

    it "should remake a request when reloaded" do
      # make a request
      Thing.find(1)
      # make the same request, but reload it
      Thing.find(1, :reload => true)
      # we should get two requests
      ActiveResource::HttpMock.requests.length.should == 2
    end

    it "should remake a request when reloaded for a string primary key" do
      # make a request
      Thing.find("fded")
      # make the same request, but reload it
      Thing.find("fded", :reload => true)
      # we should get two requests
      ActiveResource::HttpMock.requests.length.should == 2
    end

    it "should rewrite the cache when the request is reloaded" do
      # make a request
      Thing.find(1)
      # get the cached result of the request
      old_result = read_from_cache("thing/1")

      # change the response
      ActiveResource::HttpMock.reset!
      ActiveResource::HttpMock.respond_to do |mock|
        mock.get "/things/1.json", {}, @other_thing_json
      end

      Thing.find(1, :reload => true)
      new_result = read_from_cache("thing/1")
      # since active resources are equal if and only if they
      # are the same object or an instance of the same class,
      # not new?, and have the same id.
      new_result.name.should_not == old_result.name
    end

    it "should remake the request when the ttl expires" do
      # set cache time to live to 1 second
      Thing.cached_resource.ttl = 1
      # make a request
      Thing.find(1)
      # wait for the cache to expire
      sleep(1.5)
      # make the same request
      Thing.find(1)
      ActiveResource::HttpMock.requests.length.should == 2
    end

    it "should not return a frozen object on first request" do
      result1 = Thing.find(1)
      result1.should_not be_frozen
    end

    it "should not return frozen object on a subsequent request" do
      result1 = Thing.find(1)
      result2 = Thing.find(1)
      result2.should_not be_frozen
    end

    it "should not freeze first requested object on a subsequent request" do
      result1 = Thing.find(1)
      result2 = Thing.find(1)
      result1.should_not be_frozen
    end

    describe "when ActiveSupport.parse_json_times is enabled" do
      before(:all) do
        Time.zone = 'UTC'
        ActiveSupport.parse_json_times = true
      end

      it "should convert date times to objects when reading from cache" do
        Thing.find(4)

        read_from_cache("thing/4").created_at.should == @date_thing[:thing][:created_at]
      end
    end

    shared_examples "collection_return_type" do
      if ActiveResource::VERSION::MAJOR >= 4
        it "should return an ActiveResource::Collection" do
          cached = read_from_cache("thing/all")
          cached.should be_instance_of(ActiveResource::Collection)
        end

        it "should return an instance of the collection_parser" do
          Thing.cached_resource.cache.clear
          class CustomCollection < ActiveResource::Collection; end
          Thing.collection_parser = CustomCollection
          Thing.all
          cached = read_from_cache("thing/all")
          cached.should be_instance_of(CustomCollection)
        end
      else
        it "should return an Array" do
          cached = read_from_cache("thing/all")
          cached.should be_instance_of(Array)
        end
      end
    end

    shared_examples "collection_freezing" do
      it "should not return a frozen collection on first request" do
        Thing.cached_resource.cache.clear
        collection1 = Thing.all
        collection1.should_not be_frozen
      end

      it "should not return a frozen collection on a subsequent request" do
        Thing.cached_resource.cache.clear
        collection1 = Thing.all
        collection2 = Thing.all
        collection2.should_not be_frozen
      end

      it "should not freeze first requested collection on a subsequent request" do
        Thing.cached_resource.cache.clear
        result1 = Thing.all
        result2 = Thing.all
        result1.should_not be_frozen
      end

      it "should not return frozen members on first request" do
        Thing.cached_resource.cache.clear
        collection1 = Thing.all
        collection1.first.should_not be_frozen
      end

      it "should not return frozen members on a subsequent request" do
        Thing.cached_resource.cache.clear
        collection1 = Thing.all
        collection2 = Thing.all
        collection2.first.should_not be_frozen
      end

      it "should not freeze members on a subsequent request" do
        Thing.cached_resource.cache.clear
        collection1 = Thing.all
        member1 = Thing.find(1)
        collection1.first.should_not be_frozen
      end

    end

    shared_examples "collection_cache_clearing" do
      it "should empty the cache when clear_cache is called" do
        Thing.clear_cache
        read_from_cache("thing/all").should == nil
        read_from_cache("thing/1").should == nil
      end

    end

    describe "when collection synchronize is enabled" do
      before(:each) do
        Thing.cached_resource.cache.clear
        Thing.cached_resource.collection_synchronize = true

        ActiveResource::HttpMock.reset!
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things/1.json", {}, @thing_json
          mock.get "/things/fded.json", {}, @string_thing_json
          mock.get "/things.json", {}, [@thing[:thing], @string_thing[:thing]].to_json(:root => :thing)
        end

        # make a request for all things
        Thing.all
      end

      include_examples "collection_return_type"

      include_examples "collection_freezing"

      it "should write cache entries for its members" do
        result = Thing.find(1)
        string_result = Thing.find("fded")
        # only the all request should have been made
        ActiveResource::HttpMock.requests.length.should == 1
        # the result should be cached with the appropriate key
        read_from_cache("thing/1").should == result
        read_from_cache("thing/fded").should == string_result
      end

      include_examples "collection_cache_clearing"

      it "should rewrite cache entries for its members when reloaded" do
        # get the soon to be stale result so that we have a cache entry
        old_result = Thing.find(1)
        old_string_result = Thing.find("fded")
        # change the server
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things/1.json", {}, @other_thing_json
          mock.get "/things/fded.json", {}, @other_string_thing_json
          mock.get "/things.json", {}, [@other_thing[:thing], @other_string_thing[:thing]].to_json(:root => :thing)
        end
        # reload the collection
        Thing.all(:reload => true)
        # get the updated result, read from the cache
        result = Thing.find(1)
        read_from_cache("thing/all")[0].should == result
        read_from_cache("thing/all")[0].name.should == result.name
        string_result = Thing.find("fded")
        read_from_cache("thing/all")[1].should == string_result
        read_from_cache("thing/all")[1].name.should == string_result.name
      end

      it "should update the collection when an individual request is reloaded" do
        # change the server
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things/1.json", {}, @other_thing_json
          mock.get "/things/fded.json", {}, @other_string_thing_json
          mock.get "/things.json", {}, [@other_thing[:thing], @other_string_thing[:thing]].to_json(:root => :thing)
        end

        # reload the individual
        result = Thing.find(1, :reload => true)
        read_from_cache("thing/all")[0].should == result
        read_from_cache("thing/all")[0].name.should == result.name
        string_result = Thing.find("fded", :reload => true)
        read_from_cache("thing/all")[1].should == string_result
        read_from_cache("thing/all")[1].name.should == string_result.name
      end

      it "should update both the collection and the member cache entries when a subset of the collection is retrieved" do
        # create cache entries for 1 and all
        old_individual = Thing.find(1)
        old_collection = Thing.all

        # change the server
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things.json?name=Ari", {}, [@other_thing[:thing]].to_json(:root => :thing)
          mock.get "/things.json?name=Lon", {}, [@other_string_thing[:thing]].to_json(:root => :thing)
        end

        # make a request for a subset of the "mother" collection
        result = Thing.find(:all, :params => {:name => "Ari"})
        # the collection should be updated to reflect the server change
        read_from_cache("thing/all")[0].should == result[0]
        read_from_cache("thing/all")[0].name.should == result[0].name
        # the individual should be updated to reflect the server change
        read_from_cache("thing/1").should == result[0]
        read_from_cache("thing/1").name.should == result[0].name

        # make a request for a subset of the "mother" collection
        result = Thing.find(:all, :params => {:name => "Lon"})
        # the collection should be updated to reflect the server change
        read_from_cache("thing/all")[1].should == result[0]
        read_from_cache("thing/all")[1].name.should == result[0].name
        # the individual should be updated to reflect the server change
        read_from_cache("thing/fded").should == result[0]
        read_from_cache("thing/fded").name.should == result[0].name
      end

      it "should maintain the order of the collection when updating it" do
        # change the server to return a longer collection
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things.json", {}, [@thing[:thing], @thing3[:thing], @thing2[:thing], @string_thing[:thing]].to_json(:root => :thing)
        end

        # create cache entry for the collection (we reload because in before block we make an all request)
        old_collection = Thing.all(:reload => true)

        # change the server's response for the thing with id 2
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things/2.json", {}, @other_thing2.to_json(:root => :thing)
          mock.get "/things/fded.json", {}, @other_string_thing.to_json(:root => :thing)
        end

        # get thing 2, thereby updating the collection
        result = Thing.find(2, :reload => true)
        # get the updated collection from the cache
        updated_collection = Thing.all
        # name should have changed to "Jeb"
        updated_collection[2].name.should == result.name
        # the updated collection should have the elements in the same order
        old_collection.each_with_index do |thing, i|
          updated_collection[i].id.should == thing.id
        end

        # get string thing, thereby updating the collection
        string_result = Thing.find("fded", :reload => true)
        # get the updated collection from the cache
        updated_collection = Thing.all
        # name should have changed to "Lon"
        updated_collection[3].name.should == string_result.name
        # the updated collection should have the elements in the same order
        old_collection.each_with_index do |thing, i|
          updated_collection[i].id.should == thing.id
        end
      end
    end

    describe "when collection synchronize is disabled" do
      before(:each) do
        Thing.cached_resource.cache.clear
        Thing.cached_resource.collection_synchronize = false

        ActiveResource::HttpMock.reset!
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things/1.json", {}, @thing_json
          mock.get "/things/fded.json", {}, @string_thing_json
          mock.get "/things.json", {}, [@thing[:thing], @string_thing[:thing]].to_json(:root => :thing)
        end

        # make a request for all things
        Thing.all
      end

      include_examples "collection_return_type"

      include_examples "collection_freezing"

      it "should not write cache entries for its members" do
        result = Thing.find(1)
        result = Thing.find("fded")
        # both the all in the before each and this request should have been made
        ActiveResource::HttpMock.requests.length.should == 3
      end

      include_examples "collection_cache_clearing"

      it "should not update the collection when an individual request is reloaded" do
        # change the server
        ActiveResource::HttpMock.respond_to do |mock|
          mock.get "/things/1.json", {}, @other_thing_json
          mock.get "/things/fded.json", {}, @other_string_thing_json
          mock.get "/things.json", {}, [@other_thing[:thing], @other_string_thing[:thing]].to_json(:root => :thing)
        end

        # reload the individual
        result = Thing.find(1, :reload => true)
        # the ids are the same, but the names should be different
        read_from_cache("thing/all")[0].name.should_not == result.name

        # reload the individual
        string_result = Thing.find("fded", :reload => true)
        # the ids are the same, but the names should be different
        read_from_cache("thing/all")[1].name.should_not == string_result.name
      end
    end

    describe "when ttl randomization is enabled" do
      before(:each) do
        @ttl = 1
        Thing.cached_resource.ttl = @ttl
        Thing.cached_resource.ttl_randomization = true
        Thing.cached_resource.send(:sample_range, 1..2, @ttl)
        # next ttl 1.72032449344216
      end

      it "should generate a random ttl" do
        Thing.cached_resource.cache.should_receive(:write)
        Thing.cached_resource.cache.stub(:write) do |key, value, options|
          # we know the ttl should not be the same as the set ttl
          options[:expires_in].should_not == @ttl
        end

        Thing.find(1)
      end

    end
  end

  describe "when disabled" do
    before(:each) do
      Thing.cached_resource.cache.clear
      Thing.cached_resource.off!

      ActiveResource::HttpMock.reset!
      ActiveResource::HttpMock.respond_to do |mock|
        mock.get "/things/1.json", {}, @thing_json
        mock.get "/things/fded.json", {}, @string_thing_json
      end
    end

    it "should cache a response" do
      result = Thing.find(1)
      read_from_cache("thing/1").should == result
    end

    it "should cache a response for a string primary key" do
      result = Thing.find("fded")
      read_from_cache("thing/fded").should == result
    end

    it "should always remake the request" do
      Thing.find(1)
      ActiveResource::HttpMock.requests.length.should == 1
      Thing.find(1)
      ActiveResource::HttpMock.requests.length.should == 2
    end

    it "should always remake the request for a string primary key" do
      Thing.find("fded")
      ActiveResource::HttpMock.requests.length.should == 1
      Thing.find("fded")
      ActiveResource::HttpMock.requests.length.should == 2
    end

    it "should rewrite the cache for each request" do
      Thing.find(1)
      old_result = read_from_cache("thing/1")

      # change the response
      ActiveResource::HttpMock.reset!
      ActiveResource::HttpMock.respond_to do |mock|
        mock.get "/things/1.json", {}, @other_thing_json
      end

      Thing.find(1)
      new_result = read_from_cache("thing/1")
      # since active resources are equal if and only if they
      # are the same object or an instance of the same class,
      # not new?, and have the same id.
      new_result.name.should_not == old_result.name
    end

    it "should rewrite the cache for each request for a string primary key" do
      Thing.find("fded")
      old_result = read_from_cache("thing/fded")

      # change the response
      ActiveResource::HttpMock.reset!
      ActiveResource::HttpMock.respond_to do |mock|
        mock.get "/things/fded.json", {}, @other_string_thing_json
      end

      Thing.find("fded")
      new_result = read_from_cache("thing/fded")
      # since active resources are equal if and only if they
      # are the same object or an instance of the same class,
      # not new?, and have the same id.
      new_result.name.should_not == old_result.name
    end
  end

end
