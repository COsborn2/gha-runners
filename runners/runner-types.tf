# The runner types this fleet offers. A job asks for one by name:
#
#   runs-on: aws-linux-x64
#
# Each type gets its own queue and scale-up/scale-down lambdas, and launches
# instances only for jobs that ask for it, so an unused type costs nothing.
# To add one (a bigger size, arm64, ...), copy an entry, give it a new name
# and apply; the name is the label jobs use.
locals {
  runner_types = {
    "aws-linux-x64" = {
      # 2 vCPU / 8 GiB, the shape of GitHub's ubuntu-latest for private repos.
      # In order of preference (fastest first); later types are fallbacks
      # for when a type has no capacity.
      instance_types = ["m7a.large", "m7i.large", "m6a.large", "m6i.large", "m5a.large", "m5.large"]
      # Concurrent instances per repository (runners are repo-level, and
      # scale-up counts them per repo): a cost ceiling, not a reservation.
      # Fleet-wide, the account's EC2 vCPU quota is the hard ceiling.
      max_count    = 10
      disk_size_gb = 50
    }
  }

  multi_runner_config = {
    for label, type in local.runner_types : label => {
      matcherConfig = {
        # exactMatch: every label in a job's runs-on must be in this list, so
        # `runs-on: <label>` and `runs-on: [self-hosted, linux, x64, <label>]`
        # both match, and GitHub-hosted labels (ubuntu-latest, ...) never do.
        labelMatchers = [["self-hosted", "linux", "x64", label]]
        exactMatch    = true
      }

      runner_config = {
        runner_os           = "linux"
        runner_architecture = "x64"
        runner_run_as       = "ubuntu" # has passwordless sudo, like the hosted runner user
        runner_name_prefix  = "${label}-"
        runner_extra_labels = [label]

        # One job per instance, then it terminates: nothing carries over
        # between jobs. Instances launch on demand; no idle pool.
        enable_ephemeral_runners = true
        runners_maximum_count    = type.max_count
        delay_webhook_event      = 0
        # User data installs Docker and friends before the runner registers
        # (a few minutes). Scale-down terminates instances that haven't
        # registered within this window, so leave headroom.
        runner_boot_time_in_minutes    = 10
        scale_down_schedule_expression = "cron(*/5 * * * ? *)"

        # By default scale-up takes one queued job per invocation and runs one
        # invocation at a time; jobs that arrive meanwhile go back on the queue
        # for its 30-second visibility timeout, so a workflow's 8 parallel jobs
        # took ~4 minutes just to launch. A short batching window lets one
        # invocation launch a burst of jobs together, and a little concurrency
        # keeps overlapping bursts from waiting. (More than 1 concurrent
        # invocation can overshoot max_count by a runner or two in a race.)
        lambda_event_source_mapping_batch_size                         = 10
        lambda_event_source_mapping_maximum_batching_window_in_seconds = 5
        scale_up_reserved_concurrent_executions                        = 3

        # On-demand because the account's SCPs deny spot launches outright.
        # Where spot is allowed, "spot" + "price-capacity-optimized" (and
        # enable_on_demand_failover_for_errors = ["InsufficientInstanceCapacity"])
        # costs roughly a third as much.
        instance_types                  = type.instance_types
        instance_target_capacity_type   = "on-demand"
        instance_allocation_strategy    = "prioritized" # instance_types order; "lowest-price" would always pick the slowest
        create_service_linked_role_spot = false         # created once in main.tf, not per type

        # See main.tf: the prebuilt image starts the runner itself; stock
        # Ubuntu needs the user data to install and start it.
        ami = {
          id_ssm_parameter_arn = local.ami_parameter_arn
        }
        enable_userdata   = !var.use_prebuilt_image
        userdata_template = "${path.module}/templates/user-data.sh"
        block_device_mappings = [{
          device_name = "/dev/sda1" # Ubuntu's root device; the module default (/dev/xvda) is Amazon Linux's
          volume_size = type.disk_size_gb
          volume_type = "gp3"
          encrypted   = true
        }]

        # Lets you open a shell on a runner with SSM Session Manager while debugging.
        enable_ssm_on_runners = true

        # Shipped to CloudWatch Logs under /github-self-hosted-runners/<prefix>-<type>/.
        # The module's defaults use Amazon Linux paths (/var/log/messages).
        runner_log_files = [
          {
            log_group_name   = "syslog"
            prefix_log_group = true
            file_path        = "/var/log/syslog"
            log_stream_name  = "{instance_id}"
          },
          {
            log_group_name   = "user_data"
            prefix_log_group = true
            file_path        = "/var/log/user-data.log"
            log_stream_name  = "{instance_id}"
          },
          {
            log_group_name   = "runner"
            prefix_log_group = true
            file_path        = "/opt/actions-runner/_diag/Runner_**.log"
            log_stream_name  = "{instance_id}"
          },
          {
            log_group_name   = "runner-startup"
            prefix_log_group = true
            file_path        = "/var/log/runner-startup.log"
            log_stream_name  = "{instance_id}"
          },
        ]
      }
    }
  }
}
