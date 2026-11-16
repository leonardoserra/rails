# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"

class PromiseTest < ActiveRecord::TestCase
  fixtures :posts, :comments

  def test_resolved
    promise = ActiveRecord::Promise.resolved(42)

    assert promise.is_a?(ActiveRecord::Promise)
    assert_not_predicate promise, :pending?
    assert_equal 42, promise.value
    assert_equal 43, promise.then { |value| value + 1 }.value
  end

  def test_resolved_then_is_lazy
    called = false
    promise = ActiveRecord::Promise.resolved(42).then { called = true }

    assert_not called
    promise.value
    assert called
  end

  def test_all
    promise = ActiveRecord::Promise.all([Post.async_count, ActiveRecord::Promise.resolved(:cached), Comment.async_count])

    assert promise.is_a?(ActiveRecord::Promise)
    assert_equal [Post.count, :cached, Comment.count], promise.value
    assert_equal Post.count + Comment.count, ActiveRecord::Promise.all([Post.async_count, Comment.async_count]).then(&:sum).value
    assert_equal "#<ActiveRecord::Promise status=complete>", ActiveRecord::Promise.all([Post.limit(0).async_count]).inspect
  end

  def test_all_without_promises
    assert_equal [], ActiveRecord::Promise.all([]).value
  end

  def test_all_is_pending_until_every_promise_is_complete
    connection = ActiveRecord::Base.lease_connection
    skip unless connection.async_enabled?

    connection.pool.stub(:schedule_query, proc { }) do
      promise = ActiveRecord::Promise.all([ActiveRecord::Promise.resolved(:cached), Post.async_count])

      assert_predicate promise, :pending?
      assert_equal [:cached, Post.count], promise.value
      assert_not_predicate promise, :pending?
    end
  end

  def test_all_is_canceled_when_a_promise_is_canceled
    connection = ActiveRecord::Base.lease_connection
    skip unless connection.async_enabled?

    connection.pool.stub(:schedule_query, proc { }) do
      ActiveRecord::Base.asynchronous_queries_tracker.start_session
      begin
        future_result = connection.select_all("SELECT * FROM posts", async: true)
      ensure
        ActiveRecord::Base.asynchronous_queries_tracker.finalize_session
      end
      promise = ActiveRecord::Promise.all([ActiveRecord::Promise.resolved(:cached), future_result.then(&:itself)])

      assert_equal "#<ActiveRecord::Promise status=canceled>", promise.inspect
      assert_raises(ActiveRecord::FutureResult::Canceled) { promise.value }
    end
  end

  def test_all_does_not_change_when_the_given_array_changes
    promises = [ActiveRecord::Promise.resolved(1)]
    promise = ActiveRecord::Promise.all(promises)
    promises << ActiveRecord::Promise.resolved(2)

    assert_equal [1], promise.value
  end

  def test_all_raises_for_values_that_are_not_promises
    error = assert_raises(ArgumentError) { ActiveRecord::Promise.all([ActiveRecord::Promise.resolved(1), 2]) }
    assert_equal "expected an ActiveRecord::Promise, got Integer", error.message
  end

  def test_all_waits_for_every_promise_then_raises_the_first_error
    last_promise_awaited = false
    promise = ActiveRecord::Promise.all([
      ActiveRecord::Promise.resolved(nil).then { raise ArgumentError, "first" },
      ActiveRecord::Promise.resolved(nil).then { raise "second" },
      ActiveRecord::Promise.resolved(nil).then { last_promise_awaited = true },
    ])

    error = assert_raises(ArgumentError) { promise.value }
    assert_equal "first", error.message
    assert last_promise_awaited
  end
end
