require 'fileutils'

module HTMLVideoAutomator
  class Job
    def initialize
      @videos = Array.new
      @id = get_new_id
      @report_url = "#{Config['hva_host']}/job-report-#{@id}.html"
    end
    
    def prepare(files)
      # TODO: Job.prepare(files)
      # Get dropbox's content and generate hashes based on filenames or files
      # Compare those hashes with the 'files' arg and generate an array of matching elements
      #  Those will be the files to process through HVA
      # load @videos with this array
      
      report # Generate initial report for CGI request response
      
      return false # return true only if each hash from 'files' matches with a file present in the dropbox
      
      # Think where to lock mutex
    end
    
    def start
      @start_time = Time.now
      try_lock if Config['environment'] == 'production'

      files = Dropbox.list
      files.each do |file|
        video = Video.new(file)
        @videos.push(video)
      end
      
      @videos.each do |video|
        $log.info "Processing #{video.filename}"
        
        next unless do_task :validate, video
        
        next unless do_task :encode_mp4, video
        next unless do_task :encode_webm, video
        next unless do_task :gen_poster, video
        next unless do_task :gen_html, video
        
        next unless do_task :publish, video
        next unless do_task :archive, video
        
        clean_local_files(video)
      end
      
      report(:final)
      
      unlock if Config['environment'] == 'production'
    end
    
    private
    
    def do_task(task, video)
      video.tasks[task] = :working
      $log.debug "Tagged #{task.to_s} to working for #{video.name}"
      report
      
      case task
      when :validate
        result = video.valid?
      when :encode_mp4
        result = Worker.encode video, :format => 'mp4'
      when :encode_webm
        result = Worker.encode video, :format => 'webm'
      when :gen_poster
        result = Worker.gen_poster video # TODO: , :format => 'png'
      when :gen_html
        result = Worker.gen_html video
      when :publish
        result = Worker.publish video
      when :archive
        result = Worker.archive video
      end
      
      update_task(video, task, result)
      report
      return result
    end
    
    def update_task(video, task, result)
      video.tasks[task] = result ? :done : :failed
    end
    
    def get_new_id
      job_id_file = "#{Config.path('outbox')}/.job_id"
      job_id = File.exists?(job_id_file) ? File.open(job_id_file, 'r').read.to_i + 1 : 1
      
      begin
        File.open(job_id_file, 'w') do |f|
          f.write job_id
        end
      rescue Exception => e
        $log.fatal "Error getting new job id: #{e}"
        abort("Error getting new job id: #{e}")
      end
      
      $log.debug "Got job id ##{job_id}"
      return job_id
    end
    
    def report(type = :in_progress)
      Worker.gen_job_report(@id, @videos, @start_time, type)
    end
    
    def clean_local_files(video)
      $log.info "Cleaning local source and deliverables for #{video.name}"
      FileUtils.rm video.deliverables
      FileUtils.rm video.path
    end
    
    def try_lock
      begin
        FileUtils.mkdir '/tmp/hva-lock'
      rescue Exception => e
        $log.info "HVA already running. Aborting..."
        abort("HVA already running. #{e}")
      end
      $log.debug "Successfully locked mutex"
    end

    def unlock
      FileUtils.rmdir '/tmp/hva-lock'
      $log.debug "Unlocked mutex" 
    end
  end
end