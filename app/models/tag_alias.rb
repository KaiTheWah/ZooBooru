# frozen_string_literal: true

class TagAlias < TagRelationship
  has_many :tag_rel_undos, as: :tag_rel

  attr_accessor :skip_forum

  after_save :create_mod_action
  validates :antecedent_name, uniqueness: { conditions: -> { duplicate_relevant } }, unless: :is_deleted?
  validate :absence_of_transitive_relation, unless: :is_deleted?

  module ApprovalMethods
    def approve!(approver: CurrentUser.user, update_topic: true)
      CurrentUser.scoped(approver) do
        update(status: "queued", approver_id: approver.id)
        create_undo_information
        TagAliasJob.perform_later(id, update_topic)
      end
    end

    def undo!(approver: CurrentUser.user)
      CurrentUser.scoped(approver) do
        TagAliasUndoJob.perform_later(id, true)
      end
    end
  end

  module ForumMethods
    def forum_updater
      @forum_updater ||= ForumUpdater.new(
        forum_topic,
        forum_post:     (forum_post if forum_topic),
        expected_title: TagAliasRequest.topic_title(antecedent_name, consequent_name),
        skip_update:    !TagRelationship::SUPPORT_HARD_CODED,
      )
    end
  end

  module TransitiveChecks
    def list_transitives
      return @transitives if @transitives
      @transitives = []
      aliases = TagAlias.duplicate_relevant.where("consequent_name = ?", antecedent_name)
      aliases.each do |ta|
        @transitives << [:alias, ta, ta.antecedent_name, ta.consequent_name, consequent_name]
      end

      implications = TagImplication.duplicate_relevant.where("antecedent_name = ? or consequent_name = ?", antecedent_name, antecedent_name)
      implications.each do |ti|
        if ti.antecedent_name == antecedent_name
          @transitives << [:implication, ti, ti.antecedent_name, ti.consequent_name, consequent_name, ti.consequent_name]
        else
          @transitives << [:implication, ti, ti.antecedent_name, ti.consequent_name, ti.antecedent_name, consequent_name]
        end
      end

      @transitives
    end

    def has_transitives
      @has_transitives ||= !list_transitives.empty?
    end
  end

  include ApprovalMethods
  include ForumMethods
  include TransitiveChecks

  concerning :EmbeddedText do
    class_methods do
      def embedded_pattern
        /\[ta:(?<id>\d+)\]/m
      end
    end
  end

  def self.to_aliased_with_originals(names)
    names = Array(names).map(&:to_s)
    return {} if names.empty?
    aliases = active.where(antecedent_name: names).to_h { |ta| [ta.antecedent_name, ta.consequent_name] }
    names.to_h { |tag| [tag, tag] }.merge(aliases)
  end

  def self.to_aliased(names)
    TagAlias.to_aliased_with_originals(names).values
  end

  def self.to_aliased_query(query, overrides: nil)
    # Remove tag types (newline syntax)
    query.gsub!(/(^| )(-)?(#{TagCategory.mapping.keys.sort_by { |x| -x.size }.join('|')}):([\S])/i, '\1\2\4')
    # Remove tag types (comma syntax)
    query.gsub!(/, (-)?(#{TagCategory.mapping.keys.sort_by { |x| -x.size }.join('|')}):([\S])/i, ', \1\3')
    lines = query.downcase.split("\n")
    collected_tags = []
    lines.each do |line|
      tags = line.split.compact_blank.map do |x|
        negated = x[0] == "-"
        [negated ? x[1..] : x, negated]
      end
      tags.each do |t|
        collected_tags << t[0]
      end
    end
    aliased = to_aliased_with_originals(collected_tags)
    aliased.merge!(overrides) if overrides
    lines = lines.map do |line|
      tags = line.split.compact_blank.reject { |t| t == "-" }.map do |x|
        negated = x[0] == "-"
        [negated ? x[1..] : x, negated]
      end
      tags.map { |t| "#{t[1] ? '-' : ''}#{aliased[t[0]]}" }.join(" ")
    end
    lines.uniq.join("\n")
  end

  def process_undo!(update_topic: true)
    unless valid?
      raise(errors.full_messages.join("; "))
    end

    CurrentUser.scoped(approver) do
      update(status: "pending")
      CurrentUser.as_system { update_posts_locked_tags_undo }
      update_blacklists_undo
      CurrentUser.as_system { update_posts_undo }
      rename_artist_undo
      forum_updater.update(retirement_message, "UNDONE") if update_topic
    end
    tag_rel_undos.update_all(applied: true)
  end

  def update_posts_locked_tags_undo
    Post.without_timeout do
      Post.where_ilike(:locked_tags, "*#{consequent_name}*").find_each(batch_size: 50) do |post|
        fixed_tags = TagAlias.to_aliased_query(post.locked_tags, overrides: { consequent_name => antecedent_name })
        post.update_attribute(:locked_tags, fixed_tags)
      end
    end
  end

  def update_blacklists_undo
    User.without_timeout do
      User.where_ilike(:blacklisted_tags, "*#{consequent_name}*").find_each(batch_size: 50) do |user|
        fixed_blacklist = TagAlias.to_aliased_query(user.blacklisted_tags, overrides: { consequent_name => antecedent_name })
        user.update_column(:blacklisted_tags, fixed_blacklist)
      end
    end
  end

  def update_posts_undo
    Post.without_timeout do
      CurrentUser.as_system do
        tag_rel_undos.where(applied: false).find_each do |tu|
          Post.where(id: tu.undo_data).find_each do |post|
            post.automated_edit = true
            post.tag_string_diff = "-#{consequent_name} #{antecedent_name}"
            post.save
          end
        end
      end

      # TODO: Race condition with indexing jobs here.
      antecedent_tag&.fix_post_count
      consequent_tag&.fix_post_count
    end
  end

  def rename_artist_undo
    if consequent_tag.category == TagCategory.artist && (consequent_tag.artist.present? && antecedent_tag.artist.blank?)
      consequent_tag.artist.update!(name: antecedent_name)
    end
  end

  def process!(update_topic: true)
    tries = 0

    begin
      CurrentUser.scoped(approver) do
        update!(status: "processing")
        move_aliases_and_implications
        ensure_category_consistency
        CurrentUser.as_system { update_posts_locked_tags }
        update_blacklists
        CurrentUser.as_system { update_posts }
        update_followers
        rename_artist
        forum_updater.update(approval_message(approver), "APPROVED") if update_topic
        update(status: "active", post_count: consequent_tag.post_count)
        # TODO: Race condition with indexing jobs here.
        antecedent_tag.fix_post_count if antecedent_tag&.persisted?
        consequent_tag.fix_post_count if consequent_tag&.persisted?
      end
    rescue Exception => e
      Rails.logger.error("[TA] #{e.message}\n#{e.backtrace}")
      if tries < 5 && !Rails.env.test?
        tries += 1
        sleep(2**tries)
        retry
      end

      CurrentUser.scoped(approver) do
        forum_updater.update(failure_message(e), "FAILED") if update_topic
        update_columns(status: "error: #{e}")
      end
    end
  end

  def absence_of_transitive_relation
    # We don't want a -> b && b -> c chains if the b -> c alias was created first.
    # If the a -> b alias was created first, the new one will be allowed and the old one will be moved automatically instead.
    if TagAlias.active.exists?(antecedent_name: consequent_name)
      errors.add(:base, "A tag alias for #{consequent_name} already exists")
    end
  end

  def move_aliases_and_implications
    aliases = TagAlias.where(["consequent_name = ?", antecedent_name])
    aliases.each do |ta|
      ta.consequent_name = consequent_name
      success = ta.save
      if !success && ta.errors.full_messages.join("; ") =~ /Cannot alias a tag to itself/
        ta.destroy
      end
    end

    implications = TagImplication.where(["antecedent_name = ?", antecedent_name])
    implications.each do |ti|
      ti.antecedent_name = consequent_name
      success = ti.save
      if !success && ti.errors.full_messages.join("; ") =~ /Cannot implicate a tag to itself/
        ti.destroy
      end
    end

    implications = TagImplication.where(["consequent_name = ?", antecedent_name])
    implications.each do |ti|
      ti.consequent_name = consequent_name
      success = ti.save
      if !success && ti.errors.full_messages.join("; ") =~ /Cannot implicate a tag to itself/
        ti.destroy
      end
    end
  end

  def ensure_category_consistency
    return if consequent_tag.post_count > PawsMovin.config.alias_category_change_cutoff # Don't change category of large established tags.
    return if consequent_tag.is_locked? # Prevent accidentally changing tag type if category locked.
    return if consequent_tag.category != TagCategory.general # Don't change the already existing category of the target tag
    return if antecedent_tag.category == TagCategory.general # Don't set the target tag to general

    consequent_tag.update(category: antecedent_tag.category, reason: "alias ##{id} (#{antecedent_tag.name} -> #{consequent_tag.name})")
  end

  def update_blacklists
    User.without_timeout do
      User.where_ilike(:blacklisted_tags, "*#{antecedent_name}*").find_each(batch_size: 50) do |user|
        fixed_blacklist = TagAlias.to_aliased_query(user.blacklisted_tags)
        user.update_column(:blacklisted_tags, fixed_blacklist)
      end
    end
  end

  def update_posts_locked_tags
    Post.without_timeout do
      Post.where_ilike(:locked_tags, "*#{antecedent_name}*").find_each(batch_size: 50) do |post|
        fixed_tags = TagAlias.to_aliased_query(post.locked_tags)
        post.update_attribute(:locked_tags, fixed_tags)
      end
    end
  end

  def create_undo_information
    post_ids = []
    Post.transaction do
      Post.without_timeout do
        Post.sql_raw_tag_match(antecedent_name).find_each do |post|
          post_ids << post.id
        end
        tag_rel_undos.create!(undo_data: post_ids)
      end
    end
  end

  def rename_artist
    if antecedent_tag.category == TagCategory.artist && (antecedent_tag.artist.present? && consequent_tag.artist.blank?)
      antecedent_tag.artist.update!(name: consequent_name)
    end
  end

  def update_followers
    TagFollower.where(tag_id: antecedent_tag.id).find_each do |follower|
      follower.update!(tag_id: consequent_tag.id)
    end
    consequent_tag.update!(follower_count: consequent_tag.followers.count)
    antecedent_tag.update!(follower_count: 0)
  end

  def reject!(update_topic: true)
    update(status: "deleted")
    forum_updater.update(reject_message(CurrentUser.user), "REJECTED") if update_topic
  end

  def self.update_cached_post_counts_for_all
    TagAlias.without_timeout do
      connection.execute("UPDATE tag_aliases SET post_count = tags.post_count FROM tags WHERE tags.name = tag_aliases.consequent_name")
    end
  end

  def create_mod_action
    alias_desc = %("tag alias ##{id}":[#{Rails.application.routes.url_helpers.tag_alias_path(self)}]: [[#{antecedent_name}]] -> [[#{consequent_name}]])

    if previously_new_record?
      ModAction.log!(:tag_alias_create, self, alias_desc: alias_desc)
    else
      # format the changes hash more nicely.
      change_desc = saved_changes.except(:updated_at).map do |attribute, values|
        old = values[0]
        new = values[1]
        if old.nil?
          %(set #{attribute} to "#{new}")
        else
          %(changed #{attribute} from "#{old}" to "#{new}")
        end
      end.join(", ")

      ModAction.log!(:tag_alias_update, self, alias_desc: alias_desc, change_desc: change_desc)
    end
  end

  def self.fix_nonzero_post_counts!
    TagAlias.joins(:antecedent_tag).where("tag_aliases.status in ('active', 'processing') AND tags.post_count != 0").find_each { |ta| ta.antecedent_tag.fix_post_count }
  end
end
