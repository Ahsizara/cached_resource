module CachedResource
  # The Caching module is included in ActiveResource and
  # handles caching and recaching of responses.
  module Caching
    extend ActiveSupport::Concern

    included do
      class << self
        alias_method :find_without_cache, :find
        alias_method :find, :find_with_cache
      end
    end

    module ClassMethods
      # Find a resource using the cache or resend the request
      # if :reload is set to true or caching is disabled.
      def find_with_cache(*arguments)
        arguments << {} unless arguments.last.is_a?(Hash)
        should_reload = arguments.last.delete(:reload) || !cached_resource.enabled
        arguments.pop if arguments.last.empty?
        key = cache_key(arguments)

        should_reload ? find_via_reload(key, *arguments) : find_via_cache(key, *arguments)
      end

      # Clear the cache.
      def clear_cache
        cache_clear
      end

      private

      # Try to find a cached response for the given key.  If
      # no cache entry exists, send a new request.
      def find_via_cache(key, *arguments)
        cache_read(key) || find_via_reload(key, *arguments)
      end

      # Re/send the request to fetch the resource. Cache the response
      # for the request.
      def find_via_reload(key, *arguments)
        object = find_without_cache(*arguments)
        Thread.new do
          begin
            cache_collection_synchronize(object, *arguments) if cached_resource.collection_synchronize
            cache_write(key, object)
            cache_read(key)
          rescue ThreadError
          end
        end.join
        object
      end

      # If this is a pure, unadulterated "all" request
      # write cache entries for all its members
      # otherwise update an existing collection if possible.
      def cache_collection_synchronize(object, *arguments)
        if object.is_a? Enumerable
          update_singles_cache(object)
          # update the collection only if this is a subset of it
          update_collection_cache(object) unless is_collection?(*arguments)
        else
          update_collection_cache(object)
        end
      end

      # Update the cache of singles with an array of updates.
      def update_singles_cache(updates)
        updates = Array(updates)
        updates.each { |object| cache_write(cache_key(object.send(primary_key)), object) }
      end

      # Update the "mother" collection with an array of updates.
      def update_collection_cache(updates)
        updates = Array(updates)
        collection = cache_read(cache_key(cached_resource.collection_arguments))

        if collection && !updates.empty?
          index = collection.inject({}) { |hash, object| hash[object.send(primary_key)] = object; hash }
          updates.each { |object| index[object.send(primary_key)] = object }
          cache_write(cache_key(cached_resource.collection_arguments), index.values)
        end
      end

      # Determine if the given arguments represent
      # the entire collection of objects.
      def is_collection?(*arguments)
        arguments == cached_resource.collection_arguments
      end

      # Read a entry from the cache for the given key.
      def cache_read(key)
        object = cached_resource.cache.read(key).try do |json_cache|

          json = ActiveSupport::JSON.decode(json_cache)

          unless json.nil?
            cache = json_to_object(json)
            if cache.is_a? Enumerable
              restored = cache.map { |record| full_dup(record) }
              next restored unless respond_to?(:collection_parser)
              collection_parser.new(restored)
            else
              full_dup(cache)
            end
          end
        end
        object && cached_resource.logger.info("#{CachedResource::Configuration::LOGGER_PREFIX} READ #{key}")
        object
      end

      # Write an entry to the cache for the given key and value.
      def cache_write(key, object)
        result = cached_resource.cache.write(key, object_to_json(object), :race_condition_ttl => cached_resource.race_condition_ttl, :expires_in => cached_resource.generate_ttl)
        result && cached_resource.logger.info("#{CachedResource::Configuration::LOGGER_PREFIX} WRITE #{key}")
        result
      end

      # Clear the cache.
      def cache_clear
        cached_resource.cache.clear.tap do |result|
          cached_resource.logger.info("#{CachedResource::Configuration::LOGGER_PREFIX} CLEAR")
        end
      end

      # Generate the request cache key.
      def cache_key(*arguments)
        "#{name.parameterize.gsub("-", "/")}/#{arguments.join('/')}".downcase.delete(' ')
      end

      # Make a full duplicate of an ActiveResource record.
      # Currently just dups the record then copies the persisted state.
      def full_dup(record)
        record.dup.tap do |o|
          o.instance_variable_set(:@persisted, record.persisted?)
        end
      end

      def json_to_object(json)
        if json.is_a? Array
          json.map { |attrs|
            self.new(attrs["object"], attrs["persistence"]) }
        else
          self.new(json["object"], json["persistence"])
        end
      end

      def object_to_json(object)
        if object.is_a? Enumerable
           object.map { |o| { :object => o, :persistence => o.persisted? } }.to_json
        elsif object.nil?
          nil.to_json
        else
          { :object => object, :persistence => object.persisted? }.to_json
        end
      end
    end
  end
end
