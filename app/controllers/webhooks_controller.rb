# frozen_string_literal: true
class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, :authenticate_user!,
                     :set_organization, :authorize_organization_access

  before_action :verify_organization_presence
  before_action :verify_payload_signature
  before_action :verify_sender_presence
  before_action :verify_repo_presence

  def create
    if respond_to? event_handler
      send event_handler
    else
      not_found
    end
  end

  def handle_ping
    return if @organization.is_webhook_active?
    @organization.update_attributes(is_webhook_active: true)
  end

  def handle_push
    return unless params[:commits].present?
    github_repo = student_assignment_repo.github_repository
    now = Time.zone.now
    params[:commits].each do |commit|
      github_repo.create_commit_status(commit[:id],
                                       push_status(now),
                                       context: 'classroom/push',
                                       description: '')
    end
  end

  def handle_release
    github_repo = student_assignment_repo.github_repository
    sha = github_repo.ref("tags/#{params.dig(:release, :tag_name)}").object.sha
    github_repo.create_commit_status(sha, push_status(commit_pushed_at), context: 'classroom/assignment-submission')
  end

  private

  def event
    request.headers['X-GitHub-Event']
  end

  def event_handler
    @event_handler ||= "handle_#{event}".to_sym
  end

  def verify_organization_presence
    @organization ||= Organization.find_by(github_id: params.dig(:organization, :id))
    not_found unless @organization.present?
  end

  def verify_payload_signature
    algorithm, signature = request.headers['X-Hub-Signature'].split('=')

    payload_validated = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new(algorithm),
                                                ENV['WEBHOOK_SECRET'],
                                                request.body.read) == signature
    not_found unless payload_validated
  end

  def verify_sender_presence
    @sender ||= User.find_by(uid: params.dig(:sender, :id))
    not_found unless @sender.present?
  end

  def verify_repo_presence
    return true if event == 'ping'
    not_found unless student_assignment_repo.present?
  end

  def student_assignment_repo
    repo_id = params.dig(:repository, :id)
    @assignment_repo ||= AssignmentRepo.find_by(github_repo_id: repo_id)
    @assignment_repo ||= GroupAssignmentRepo.find_by(github_repo_id: repo_id)
  end

  def assignment
    if student_assignment_repo.respond_to?(:assignment)
      student_assignment_repo.assignment
    else
      student_assignment_repo.group_assignment
    end
  end

  def push_status(pushed_at)
    return 'success' unless assignment.due_date.present?
    pushed_at <= assignment.due_date ? 'success' : 'failure'
  end

  def commit_pushed_at(sha)
    combined_status = github_repo.status(sha)
    combined_status.statuses.select { |status| status.context == 'classroom/push' }.first.updated_at
  end
end
