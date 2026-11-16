# frozen_string_literal: true

module ActiveRecord
  class Promise < BasicObject
    undef_method :==, :!, :!=

    class << self
      # Returns an already resolved `ActiveRecord::Promise` holding +value+.
      #
      # Useful when a method returns either a pending query or a value it already
      # has, such as a cached result:
      #
      # ```
      # def async_title
      #   return ActiveRecord::Promise.resolved(@title) if @title
      #
      #   Post.async_pick(:title)
      # end
      # ```
      def resolved(value)
        new(FutureResult::Complete.new(value), nil)
      end

      # Returns an `ActiveRecord::Promise` whose value is the array of the values
      # of +promises+, in the same order.
      #
      # Accessing `#value` waits for every promise, then raises the error of the
      # first one that failed, in the order given. Unlike JavaScript's
      # `Promise.all`, it does not raise as soon as one promise fails, so no query
      # is left running in the background.
      #
      # ```
      # ActiveRecord::Promise.all([Post.async_count, Comment.async_count]).then(&:sum).value
      # # => 42
      # ```
      def all(promises)
        promises = promises.to_a.dup
        promises.each do |promise|
          raise ArgumentError, "expected an ActiveRecord::Promise, got #{promise.class}" unless Promise === promise
        end

        new(All.new(promises), nil)
      end
    end

    def initialize(future_result, block) # :nodoc:
      @future_result = future_result
      @block = block
    end

    # Returns whether the associated query is still being executed or not.
    def pending?
      @future_result.pending?
    end

    def canceled? # :nodoc:
      @future_result.canceled?
    end

    # Returns the query result.
    # If the query wasn't completed yet, accessing `#value` will block until the query completes.
    # If the query failed, `#value` will raise the corresponding error.
    def value
      return @value if defined? @value

      result = @future_result.result
      @value = if @block
        @block.call(result)
      else
        result
      end
    end

    # Returns a new `ActiveRecord::Promise` that will apply the passed block
    # when the value is accessed:
    #
    # ```
    # Post.async_pick(:title).then { |title| title.upcase }.value
    # # => "POST TITLE"
    # ```
    def then(&block)
      Promise.new(@future_result, @block ? @block >> block : block)
    end

    [:class, :respond_to?, :is_a?].each do |method|
      define_method(method, ::Object.instance_method(method))
    end

    def inspect # :nodoc:
      "#<ActiveRecord::Promise status=#{status}>"
    end

    def pretty_print(q) # :nodoc:
      q.text(inspect)
    end

    private
      def status
        if @future_result.pending?
          :pending
        elsif @future_result.canceled?
          :canceled
        else
          :complete
        end
      end

      class All # :nodoc:
        def initialize(promises)
          @promises = promises
        end

        def pending?
          @promises.any?(&:pending?)
        end

        def canceled?
          @promises.any?(&:canceled?)
        end

        def result
          error = nil
          values = @promises.map do |promise|
            promise.value
          rescue => e
            error ||= e
          end
          raise error if error

          values
        end
      end

      class Complete < self # :nodoc:
        attr_reader :value

        def initialize(value)
          @value = value
        end

        def then
          Complete.new(yield @value)
        end

        def pending?
          false
        end

        def canceled?
          false
        end

        private
          def status
            :complete
          end
      end
  end
end
