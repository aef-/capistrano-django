after 'deploy:updating', 'python:create_virtualenv'

namespace :deploy do

  desc 'Restart application'
  task :restart do
    if fetch(:nginx)
      invoke 'deploy:nginx_restart'
    else
      on roles(:web) do |h|
        execute "sudo apache2ctl graceful"
      end
    end
  end

  task :nginx_restart do
    on roles(:web) do |h|
      within project_path do
        pid_file = "#{releases_path}/gunicorn.pid"
        if test "[ -e #{pid_file} ]"
          execute "kill `cat #{pid_file}`"
        end
        execute "virtualenv/bin/gunicorn", "#{fetch(:wsgi_file)}:application", '-c=gunicorn_config.py', "--pid=#{pid_file}"
      end
    end
  end

end

namespace :python do

  def virtualenv_path
    File.join(
      fetch(:shared_virtualenv) ? shared_path : release_path, "virtualenv"
    )
  end

  desc "Create a python virtualenv"
  task :create_virtualenv do
    on roles(:all) do |h|
      execute "virtualenv #{virtualenv_path}"
      execute "#{virtualenv_path}/bin/pip install -r #{release_path}/#{fetch(:pip_requirements)}"
      if fetch(:shared_virtualenv)
        execute :ln, "-s", virtualenv_path, File.join(release_path, 'virtualenv')
      end
    end

    if fetch(:npm_tasks)
      invoke 'nodejs:npm'
    end
    if fetch(:flask)
      invoke 'flask:setup'
    else
      invoke 'django:setup'
    end
  end

end

namespace :flask do

  task :setup do
    on roles(:web) do |h|
      execute "ln -s #{release_path}/settings/#{fetch(:settings_file)}.py #{release_path}/settings/deployed.py"
      execute "ln -sf #{release_path}/wsgi/wsgi.py #{release_path}/wsgi/live.wsgi"
    end
  end

end

namespace :django do

  def django(args, flags="", run_on=:all)
    on roles(run_on) do |h|
      manage_path = File.join(release_path, fetch(:django_project_dir) || '', 'manage.py')
      execute "#{release_path}/virtualenv/bin/python #{manage_path} #{fetch(:django_settings)} #{args} #{flags}"
    end
  end

  after 'deploy:restart', 'django:restart_celery'

  desc "Setup Django environment"
  task :setup do
    if fetch(:django_compressor)
      invoke 'django:compress'
    end
    invoke 'django:compilemessages'
    invoke 'django:collectstatic'
    invoke 'django:symlink_settings'
    if !fetch(:nginx)
      invoke 'django:symlink_wsgi'
    end
    invoke 'django:migrate'
  end

  desc "Compile Messages"
  task :compilemessages do
    if fetch :compilemessages
      django("compilemessages")
    end
  end

  desc "Restart Celery"
  task :restart_celery do
    if fetch(:celery_name)
      invoke 'django:restart_celeryd'
      invoke 'django:restart_celerybeat'
    end
  end

  desc "Restart Celeryd"
  task :restart_celeryd do
    on roles(:jobs) do
      execute "sudo service celeryd-#{fetch(:celery_name)} restart"
    end
  end

  desc "Restart Celerybeat"
  task :restart_celerybeat do
    on roles(:jobs) do
      execute "sudo service celerybeat-#{fetch(:celery_name)} restart"
    end
  end

  desc "Run django-compressor"
  task :compress do
    django("compress")
  end

  desc "Run django's collectstatic"
  task :collectstatic do
    django("collectstatic", "-i *.coffee -i *.less -i node_modules/* -i bower_components/* --noinput")
  end

  desc "Symlink django settings to deployed.py"
  task :symlink_settings do
    settings_path = File.join(release_path, fetch(:django_settings_dir))
    on roles(:all) do
      execute "ln -s #{settings_path}/#{fetch(:django_settings)}.py #{settings_path}/deployed.py"
    end
  end

  desc "Symlink wsgi script to live.wsgi"
  task :symlink_wsgi do
    on roles(:web) do
      wsgi_path = File.join(release_path, fetch(:wsgi_path, 'wsgi'))
      execute "ln -sf #{wsgi_path}/main.wsgi #{wsgi_path}/live.wsgi"
    end
  end

  desc "Run django migrations"
  task :migrate do
    if fetch(:multidb)
      django("sync_all", '--noinput', run_on=:web)
    else
      django("migrate", "--noinput", run_on=:web)
    end
  end
end

namespace :nodejs do

  desc 'Install node modules'
  task :npm_install do
    on roles(:web) do
      path = fetch(:npm_path) ? File.join(release_path, fetch(:npm_path)) : release_path
      within path do
        execute 'npm', 'install', fetch(:npm_install_production, '--production')
      end
    end
  end

  desc 'Run npm tasks'
  task :npm do
    invoke 'nodejs:npm_install'
    on roles(:web) do
      path = fetch(:npm_path) ? File.join(release_path, fetch(:npm_path)) : release_path
      within path do
        fetch(:npm_tasks).each do |task, args|
          execute "./node_modules/.bin/#{task}", args
        end
      end
    end
  end

end
