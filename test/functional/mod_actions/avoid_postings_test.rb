# frozen_string_literal: true

require "test_helper"
require_relative "helper"

module ModActions
  class AvoidPostingsTest < ActiveSupport::TestCase
    include Helper
    include Rails.application.routes.url_helpers

    context "mod actions for avoid posting entries" do
      setup do
        @avoid_posting = create(:avoid_posting)
        set_count!
      end

      should "parse avoid_posting_create correctly" do
        @avoid_posting = create(:avoid_posting)

        assert_matches(
          actions:     %w[avoid_posting_create],
          text:        "Created avoid posting for artist \"#{@avoid_posting.artist_name}\":#{show_or_new_artists_path(name: @avoid_posting.artist_name)}",
          subject:     @avoid_posting,
          artist_name: @avoid_posting.artist_name,
        )
      end

      should "parse avoid_posting_delete correctly" do
        @avoid_posting.update(is_active: false)

        assert_matches(
          actions:     %w[avoid_posting_delete],
          text:        "Deleted avoid posting for artist \"#{@avoid_posting.artist_name}\":#{show_or_new_artists_path(name: @avoid_posting.artist_name)}",
          subject:     @avoid_posting,
          artist_name: @avoid_posting.artist_name,
        )
      end

      should "parse avoid_posting_destroy correctly" do
        @avoid_posting.destroy

        assert_matches(
          actions:     %w[avoid_posting_destroy],
          text:        "Destroyed avoid posting for artist \"#{@avoid_posting.artist_name}\":#{show_or_new_artists_path(name: @avoid_posting.artist_name)}",
          subject:     @avoid_posting,
          artist_name: @avoid_posting.artist_name,
        )
      end

      should "parse avoid_posting_undelete correctly" do
        @avoid_posting.update_columns(is_active: false)
        @avoid_posting.update(is_active: true)

        assert_matches(
          actions:     %w[avoid_posting_undelete],
          text:        "Undeleted avoid posting for artist \"#{@avoid_posting.artist_name}\":#{show_or_new_artists_path(name: @avoid_posting.artist_name)}",
          subject:     @avoid_posting,
          artist_name: @avoid_posting.artist_name,
        )
      end

      should "parse avoid_posting_update correctly" do
        @avoid_posting.update(details: "foo")

        assert_matches(
          actions:     %w[avoid_posting_update],
          text:        "Updated avoid posting for artist \"#{@avoid_posting.artist_name}\":#{show_or_new_artists_path(name: @avoid_posting.artist_name)}",
          subject:     @avoid_posting,
          artist_name: @avoid_posting.artist_name,
        )
      end
    end
  end
end
