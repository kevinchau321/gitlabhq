require 'spec_helper'

describe MergeRequests::RefreshService, services: true do
  let(:project) { create(:project, :repository) }
  let(:user) { create(:user) }
  let(:service) { MergeRequests::RefreshService }

  describe '#execute' do
    before do
      @user = create(:user)
      group = create(:group)
      group.add_owner(@user)

      @project = create(:project, :repository, namespace: group)
      @fork_project = Projects::ForkService.new(@project, @user).execute
      @merge_request = create(:merge_request,
                              source_project: @project,
                              source_branch: 'master',
                              target_branch: 'feature',
                              target_project: @project,
                              merge_when_pipeline_succeeds: true,
                              merge_user: @user)

      @fork_merge_request = create(:merge_request,
                                   source_project: @fork_project,
                                   source_branch: 'master',
                                   target_branch: 'feature',
                                   target_project: @project)

      @build_failed_todo = create(:todo,
                                  :build_failed,
                                  user: @user,
                                  project: @project,
                                  target: @merge_request,
                                  author: @user)

      @fork_build_failed_todo = create(:todo,
                                       :build_failed,
                                       user: @user,
                                       project: @project,
                                       target: @merge_request,
                                       author: @user)

      @commits = @merge_request.commits

      @oldrev = @commits.last.id
      @newrev = @commits.first.id
    end

    context 'push to origin repo source branch' do
      let(:refresh_service) { service.new(@project, @user) }
      before do
        allow(refresh_service).to receive(:execute_hooks)
        refresh_service.execute(@oldrev, @newrev, 'refs/heads/master')
        reload_mrs
      end

      it 'executes hooks with update action' do
        expect(refresh_service).to have_received(:execute_hooks).
          with(@merge_request, 'update', @oldrev)

        expect(@merge_request.notes).not_to be_empty
        expect(@merge_request).to be_open
        expect(@merge_request.merge_when_pipeline_succeeds).to be_falsey
        expect(@merge_request.diff_head_sha).to eq(@newrev)
        expect(@fork_merge_request).to be_open
        expect(@fork_merge_request.notes).to be_empty
        expect(@build_failed_todo).to be_done
        expect(@fork_build_failed_todo).to be_done
      end
    end

    context 'push to origin repo target branch' do
      before do
        service.new(@project, @user).execute(@oldrev, @newrev, 'refs/heads/feature')
        reload_mrs
      end

      it 'updates the merge state' do
        expect(@merge_request.notes.last.note).to include('merged')
        expect(@merge_request).to be_merged
        expect(@fork_merge_request).to be_merged
        expect(@fork_merge_request.notes.last.note).to include('merged')
        expect(@build_failed_todo).to be_done
        expect(@fork_build_failed_todo).to be_done
      end
    end

    context 'manual merge of source branch' do
      before do
        # Merge master -> feature branch
        author = { email: 'test@gitlab.com', time: Time.now, name: "Me" }
        commit_options = { message: 'Test message', committer: author, author: author }
        @project.repository.merge(@user, @merge_request.diff_head_sha, @merge_request, commit_options)
        commit = @project.repository.commit('feature')
        service.new(@project, @user).execute(@oldrev, commit.id, 'refs/heads/feature')
        reload_mrs
      end

      it 'updates the merge state' do
        expect(@merge_request.notes.last.note).to include('merged')
        expect(@merge_request).to be_merged
        expect(@merge_request.diffs.size).to be > 0
        expect(@fork_merge_request).to be_merged
        expect(@fork_merge_request.notes.last.note).to include('merged')
        expect(@build_failed_todo).to be_done
        expect(@fork_build_failed_todo).to be_done
      end
    end

    context 'push to fork repo source branch' do
      let(:refresh_service) { service.new(@fork_project, @user) }

      context 'open fork merge request' do
        before do
          allow(refresh_service).to receive(:execute_hooks)
          refresh_service.execute(@oldrev, @newrev, 'refs/heads/master')
          reload_mrs
        end

        it 'executes hooks with update action' do
          expect(refresh_service).to have_received(:execute_hooks).
            with(@fork_merge_request, 'update', @oldrev)

          expect(@merge_request.notes).to be_empty
          expect(@merge_request).to be_open
          expect(@fork_merge_request.notes.last.note).to include('added 28 commits')
          expect(@fork_merge_request).to be_open
          expect(@build_failed_todo).to be_pending
          expect(@fork_build_failed_todo).to be_pending
        end
      end

      context 'closed fork merge request' do
        before do
          @fork_merge_request.close!
          allow(refresh_service).to receive(:execute_hooks)
          refresh_service.execute(@oldrev, @newrev, 'refs/heads/master')
          reload_mrs
        end

        it 'do not execute hooks with update action' do
          expect(refresh_service).not_to have_received(:execute_hooks)
        end

        it 'updates merge request to closed state' do
          expect(@merge_request.notes).to be_empty
          expect(@merge_request).to be_open
          expect(@fork_merge_request.notes).to be_empty
          expect(@fork_merge_request).to be_closed
          expect(@build_failed_todo).to be_pending
          expect(@fork_build_failed_todo).to be_pending
        end
      end
    end

    context 'push to fork repo target branch' do
      describe 'changes to merge requests' do
        before do
          service.new(@fork_project, @user).execute(@oldrev, @newrev, 'refs/heads/feature')
          reload_mrs
        end

        it 'updates the merge request state' do
          expect(@merge_request.notes).to be_empty
          expect(@merge_request).to be_open
          expect(@fork_merge_request.notes).to be_empty
          expect(@fork_merge_request).to be_open
          expect(@build_failed_todo).to be_pending
          expect(@fork_build_failed_todo).to be_pending
        end
      end

      describe 'merge request diff' do
        it 'does not reload the diff of the merge request made from fork' do
          expect do
            service.new(@fork_project, @user).execute(@oldrev, @newrev, 'refs/heads/feature')
          end.not_to change { @fork_merge_request.reload.merge_request_diff }
        end
      end
    end

    context 'push to origin repo target branch after fork project was removed' do
      before do
        @fork_project.destroy
        service.new(@project, @user).execute(@oldrev, @newrev, 'refs/heads/feature')
        reload_mrs
      end

      it 'updates the merge request state' do
        expect(@merge_request.notes.last.note).to include('merged')
        expect(@merge_request).to be_merged
        expect(@fork_merge_request).to be_open
        expect(@fork_merge_request.notes).to be_empty
        expect(@build_failed_todo).to be_done
        expect(@fork_build_failed_todo).to be_done
      end
    end

    context 'push new branch that exists in a merge request' do
      let(:refresh_service) { service.new(@fork_project, @user) }

      it 'refreshes the merge request' do
        expect(refresh_service).to receive(:execute_hooks).
                                       with(@fork_merge_request, 'update', Gitlab::Git::BLANK_SHA)
        allow_any_instance_of(Repository).to receive(:merge_base).and_return(@oldrev)

        refresh_service.execute(Gitlab::Git::BLANK_SHA, @newrev, 'refs/heads/master')
        reload_mrs

        expect(@merge_request.notes).to be_empty
        expect(@merge_request).to be_open

        notes = @fork_merge_request.notes.reorder(:created_at).map(&:note)
        expect(notes[0]).to include('restored source branch `master`')
        expect(notes[1]).to include('added 28 commits')
        expect(@fork_merge_request).to be_open
      end
    end

    context 'merge request metrics' do
      let(:issue) { create :issue, project: @project }
      let(:commit_author) { create :user }
      let(:commit) { project.commit }

      before do
        project.team << [commit_author, :developer]
        project.team << [user, :developer]

        allow(commit).to receive_messages(
          safe_message: "Closes #{issue.to_reference}",
          references: [issue],
          author_name: commit_author.name,
          author_email: commit_author.email,
          committed_date: Time.now
        )

        allow_any_instance_of(MergeRequest).to receive(:commits).and_return([commit])
      end

      context 'when the merge request is sourced from the same project' do
        it 'creates a `MergeRequestsClosingIssues` record for each issue closed by a commit' do
          merge_request = create(:merge_request, target_branch: 'master', source_branch: 'feature', source_project: @project)
          refresh_service = service.new(@project, @user)
          allow(refresh_service).to receive(:execute_hooks)
          refresh_service.execute(@oldrev, @newrev, 'refs/heads/feature')

          issue_ids = MergeRequestsClosingIssues.where(merge_request: merge_request).pluck(:issue_id)
          expect(issue_ids).to eq([issue.id])
        end
      end

      context 'when the merge request is sourced from a different project' do
        it 'creates a `MergeRequestsClosingIssues` record for each issue closed by a commit' do
          forked_project = create(:project, :repository)
          create(:forked_project_link, forked_to_project: forked_project, forked_from_project: @project)

          merge_request = create(:merge_request,
                                 target_branch: 'master',
                                 source_branch: 'feature',
                                 target_project: @project,
                                 source_project: forked_project)
          refresh_service = service.new(@project, @user)
          allow(refresh_service).to receive(:execute_hooks)
          refresh_service.execute(@oldrev, @newrev, 'refs/heads/feature')

          issue_ids = MergeRequestsClosingIssues.where(merge_request: merge_request).pluck(:issue_id)
          expect(issue_ids).to eq([issue.id])
        end
      end
    end

    context 'marking the merge request as work in progress' do
      let(:refresh_service) { service.new(@project, @user) }
      before do
        allow(refresh_service).to receive(:execute_hooks)
      end

      it 'marks the merge request as work in progress from fixup commits' do
        fixup_merge_request = create(:merge_request,
                                     source_project: @project,
                                     source_branch: 'wip',
                                     target_branch: 'master',
                                     target_project: @project)
        commits = fixup_merge_request.commits
        oldrev = commits.last.id
        newrev = commits.first.id

        refresh_service.execute(oldrev, newrev, 'refs/heads/wip')
        fixup_merge_request.reload

        expect(fixup_merge_request.work_in_progress?).to eq(true)
        expect(fixup_merge_request.notes.last.note).to match(
          /marked as a \*\*Work In Progress\*\* from #{Commit.reference_pattern}/
        )
      end

      it 'references the commit that caused the Work in Progress status' do
        refresh_service.execute(@oldrev, @newrev, 'refs/heads/master')
        allow(refresh_service).to receive(:find_new_commits)
        refresh_service.instance_variable_set("@commits", [
          double(
            id: 'aaaaaaa',
            sha: '38008cb17ce1466d8fec2dfa6f6ab8dcfe5cf49e',
            short_id: 'aaaaaaa',
            title: 'Fix issue',
            work_in_progress?: false
          ),
          double(
            id: 'bbbbbbb',
            sha: '498214de67004b1da3d820901307bed2a68a8ef6',
            short_id: 'bbbbbbb',
            title: 'fixup! Fix issue',
            work_in_progress?: true,
            to_reference: 'bbbbbbb'
          ),
          double(
            id: 'ccccccc',
            sha: '1b12f15a11fc6e62177bef08f47bc7b5ce50b141',
            short_id: 'ccccccc',
            title: 'fixup! Fix issue',
            work_in_progress?: true,
            to_reference: 'ccccccc'
          ),
        ])
        refresh_service.execute(@oldrev, @newrev, 'refs/heads/wip')
        reload_mrs
        expect(@merge_request.notes.last.note).to eq(
          "marked as a **Work In Progress** from bbbbbbb"
        )
      end

      it 'does not mark as WIP based on commits that do not belong to an MR' do
        allow(refresh_service).to receive(:find_new_commits)
        refresh_service.instance_variable_set("@commits", [
          double(
            id: 'aaaaaaa',
            sha: 'aaaaaaa',
            short_id: 'aaaaaaa',
            title: 'Fix issue',
            work_in_progress?: false
          ),
          double(
            id: 'bbbbbbb',
            sha: 'bbbbbbbb',
            short_id: 'bbbbbbb',
            title: 'fixup! Fix issue',
            work_in_progress?: true,
            to_reference: 'bbbbbbb'
          )
        ])

        refresh_service.execute(@oldrev, @newrev, 'refs/heads/master')
        reload_mrs

        expect(@merge_request.work_in_progress?).to be_falsey
      end
    end

    def reload_mrs
      @merge_request.reload
      @fork_merge_request.reload
      @build_failed_todo.reload
      @fork_build_failed_todo.reload
    end
  end
end
