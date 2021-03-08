package web::BackendServer;

# Make this subclass a Mojolicious app
use Mojo::Base 'Mojolicious';
use Mojo::Util qw(trim);

use ksb::Application;
use ksb::Debug qw(pretending);
use ksb::dto::ModuleGraph;
use ksb::dto::ModuleInfo;
use ksb::DependencyResolver;

use Cwd;

# This is written in a kind of domain-specific language for Mojolicious for
# now, to setup a web server backend for clients / frontends to communicate
# with.
# See https://mojolicious.org/perldoc/Mojolicious/Guides/Tutorial

# Used to collect kdesrc-build runtime information as part of the Mojolicious
# web application
has 'ksb_state';

sub new
{
    my ($class, $config) = @_;

    # Mojolicious will provide configuration input in a dictionary keyed by
    # 'config' so that's where we need to look for it
    $config //= { config => { } };

    my $optsAndSelectors = $config->{config};
    $optsAndSelectors->{options}   //= {};
    $optsAndSelectors->{selectors} //= [];

    return $class->SUPER::new(
        ksb_state => {
            ksb     => undef, # Will be set automatically when needed
            ksbhome => getcwd(),

            build_result => undef, # Set when the build completes
            build_promise => undef, # Set when build ongoing

            options => $optsAndSelectors->{options},
            selectors => $optsAndSelectors->{selectors},
            opts_and_selectors => $optsAndSelectors,
        },
    );
}

# Adds a helper method to each HTTP context object to return the
# ksb::Application class in use
sub make_new_ksb
{
    my $c = shift;

    # ksb::Application startup uses current dir to find right rc-file
    # by default.
    chdir($c->app->ksb_state->{ksbhome});
    my $app = ksb::Application->new->setHeadless;

    # Note that we shouldn't /have/ any selectors at this point, it's now a
    # separate user input.
    my @selectors = $app->establishContext($c->app->ksb_state->{opts_and_selectors});
    $c->app->ksb_state->{selectors} = [@selectors];

    # Reset log handler
    my $ctx = $app->context();
    if (pretending()) {
        # Mojolicious will install a file watch on the log path so it has to exist
        # if we set it. Instead just de-spam the output to TTY for now.
        $c->app->log->level('error');
    } else {
        $c->app->log(Mojo::Log->new(
                path => $ctx->getLogDirFor($ctx) . "/mojo-backend.log",
                level => (exists $ENV{KDESRC_BUILD_DEBUG} ? 'debug' : 'info'),
                ));
    }

    if (ksb::Debug::debugging()) {
        $c->app->log->level('debug');
        $c->app->log->on(message => sub {
            my ($log, $level, @lines) = @_;
            say STDERR "[$level] ", @lines;
        });
    }

    if (@selectors) {
        $c->app->log->info("Module selectors requested:" . join(', ', @selectors));
    } else {
        $c->app->log->info("All modules to be built");
    }

    return $app;
}

sub startup {
    my $self = shift;

    # Force use of 'modules/web' as the home directory, would normally be
    # 'modules' alone
    $self->home($self->home->child('web'));

    # Fixup templates and public base directories
    $self->static->paths->[0]   = $self->home->child('public');
    $self->renderer->paths->[0] = $self->home->child('templates');

    $self->helper(ksb => sub {
        my ($c, $new_ksb) = @_;

        $c->app->ksb_state->{ksb} = $new_ksb
            if $new_ksb;

        $c->app->ksb_state->{ksb} //= make_new_ksb($c);

        return $c->app->ksb_state->{ksb};
    });

    $self->helper(in_build => sub { defined (shift->app->ksb_state->{build_promise}) });
    $self->helper(context  => sub { shift->ksb->context() });

    my $r = $self->routes;
    $self->_generateRoutes;

    # We will need module metadata but if we're running in the test suite then
    # assume needed metadata will be provided as part of the test.
    $self->ksb->_downloadKDEProjectMetadata()
        unless exists $ENV{HARNESS_ACTIVE};

    return;
}

# Generates HTTP response for ksb::BuildExceptions. Note that the 'to_string'
# overload is called by Mojo if you don't specifically copy the needed values
# into a plain map.
sub _renderException {
    my ($self, $c, $err) = @_;

    my $out = { };

    if (!ref $err || ref $err eq 'STRING') {
        $out->{message}        = $err;
        $out->{exception_type} = 'Runtime';
    } else {
        $out->{message}        = $@->{message};
        $out->{exception_type} = $@->{exception_type};
    }

    return $c->render(json => $out, status => 400);
}

sub _generateRoutes {
    my $self = shift;
    my $r = $self->routes;

    # Defaults to showing status and useful links
    $r->get('/' => sub {
        my $c = shift;

        return $c->render(
            template => 'index',
            ctx => $c->app->ksb->context(),
        );
    })->name('index');

    # No data needs fed to it so Mojolicious default template based on route
    # name is all we need
    $r->get('/setup_new_build' => 'setup_new_build');

    $r->post('/reset' => sub {
        my $c = shift;

        if ($c->in_build || !defined $c->app->ksb_state->{build_result}) {
            return $c->render(status => 400, json => { error => "Not ready to reset" });
        }

        my $old_result = $c->app->ksb_state->{build_result};
        $c->ksb(make_new_ksb($c));
        $c->app->ksb_state->{build_result} = undef;

        $c->render(json => { last_result => $old_result });
    });

    $r->get('/context/options' => sub {
        my $c = shift;
        $c->render(json => $c->ksb->context()->{options});
    });

    $r->get('/context/options/:option' => sub {
        my $c = shift;
        my $ctx = $c->ksb->context();

        my $opt = $c->param('option') or do {
            return $self->_renderException($c, 'Invalid request sent');
        };

        if (defined $ctx->{options}->{$opt}) {
            $c->render(json => { $opt => $ctx->{options}->{$opt} });
        }
        else {
            $c->reply->not_found;
        }
    });

    $r->get('/modules' => sub {
        my $c = shift;
        eval {
            $c->render(json => [$c->ksb->modules()]);
        };

        return $self->_renderException($c, $@) if $@;
    } => 'module_lookup');

    $r->get('/known_modules' => sub {
        my $c = shift;
        my $resolver = $c->ksb->{module_resolver};
        my @setsAndModules = @{$resolver->{inputModulesAndOptions}};
        my @output = map {
            $_->isa('ksb::ModuleSet')
                ? [ $_->name(), $_->moduleNamesToFind() ]
                : $_->name() # should be a ksb::Module
        } @setsAndModules;

        $c->render(json => \@output);
    });

    $r->post('/modules' => sub {
        my $c = shift;
        my $selectorList = $c->req->json;
        my $build_all = $c->req->headers->header('X-BuildAllModules');
        my $log = $c->app->log;

        # Remove empty selectors
        my @selectors = grep { !!$_ } map { trim($_ // '') } @{$selectorList};

        $log->warn("We're already in a build") if $c->in_build;
        if ($build_all) {
            $log->info("User requested to build all modules");
        } else {
            my $exactList = $c->req->text;
            $log->info("User requested to build $exactList: [" . join(', ', @selectors) . "]");
        }

        # If not building all then ensure there's at least one module to build
        if ($c->in_build || !$selectorList || (!@selectors && !$build_all) || (@selectors && $build_all)) {
            $log->error("Something was wrong with modules to assign to build");
            return $self->_renderException($c, 'Invalid selectors requested to build');
        }

        eval {
            my $workload = $c->ksb->modulesFromSelectors(@selectors);
            $c->ksb->setModulesToProcess($workload);
            $c->app->ksb_state->{selectors} = \@selectors;
        };

        return $self->_renderException($c, $@)
            if $@;

        my $numSels = scalar @selectors;

        $c->render(json => ["$numSels handled"]);
    }, 'post_modules');

    $r->get('/module/:modname' => sub {
        my $c = shift;
        my $name = $c->stash('modname');

        my $module = $c->ksb->context()->lookupModule($name);
        if (!$module) {
            $c->render(template => 'does_not_exist');
            return;
        }

        my $opts = {
            options => $module->{options},
            persistent => $c->ksb->context()->{persistent_options}->{$name},
        };
        $c->render(json => $opts);
    });

    $r->get('/module/:modname/logs/error' => sub {
        my $c = shift;
        my $name = $c->stash('modname');
        $c->render(text => "TODO: Error logs for $name");
    });

    $r->get('/config' => sub {
        my $c = shift;
        $c->render(text => $c->ksb->context()->rcFile());
    });

    $r->post('/config' => sub {
        # TODO If new filename can be loaded, load it and reset application object
        die "Unimplemented";
    });

    $r->get('/build-metadata' => sub {
        die "Unimplemented";
    });

    $r->websocket('/events' => sub {
        my $c = shift;

        $c->inactivity_timeout(0);

        my $ctx = $c->ksb->context();
        my $monitor = $ctx->statusMonitor();

        # Send prior events the receiver wouldn't have received yet
        my @curEvents = $monitor->events();
        $c->send({json => \@curEvents});

        # Hook up an event handler to send future events as they're generated
        $monitor->on(newEvent => sub {
            my ($monitor, $resultRef) = @_;
            $c->on(drain => sub { $c->finish })
                if ($resultRef->{event} eq 'build_done');
            $c->send({json => [ $resultRef ]});
        });
    });

    $r->get('/event_viewer' => sub {
        my $c = shift;
        $c->render(template => 'event_viewer');
    });

    $r->get('/building' => sub {
        my $c = shift;
        $c->render(text => $c->in_build ? 'True' : 'False');
    });

    $r->get('/moduleGraph' => sub {
        my $c = shift;
        my $work = $c->app->ksb->workLoad() // {};
        my $info = $work->{dependencyInfo};

        if (defined($info)) {
            my $dto = ksb::dto::ModuleGraph::dependencyInfoToDto($info);
            $c->render(json => $dto);
        }
        else {
            $c->reply->not_found;
        }
    });

    $r->get('/modulesFromCommand' => sub {
        my $c = shift;
        my $work = $c->app->ksb->workLoad() // {};
        my $info = $work->{dependencyInfo};

        if (!defined($info)
            || ksb::DependencyResolver::hasErrors($info)
            || !exists $info->{graph})
        {
            $c->reply->not_found;
            return;
        }

        my $graph = $info->{graph};
        my $modules = $work->{modulesFromCommand};
        my @dtos = ksb::dto::ModuleInfo::selectedModulesToDtos(
            $graph,
            $modules
        );

        #
        # Trap for the unwary: make sure to return a reference.
        # Without this Mojolicious won't encode the array properly
        #
        $c->render(json => \@dtos);
    });

    $r->post('/build' => sub {
        my $c = shift;

        if ($c->context->getOption('metadata-only')) {
            my $msg = 'There is nothing to do, only metadata update was requested.';
            $c->res->code(204);
            $c->app->log->info($msg);
            $c->render(text => $msg);
            return;
        }

        if ($c->in_build) {
            $c->res->code(400);
            $c->render(text => 'Build already in progress, cancel it first.');
            return;
        }

        $c->app->log->debug('Starting build');

        $c->app->ksb_state->{build_promise} = $c->ksb->startHeadlessBuild->then(sub{
            my ($result) = @_;
            $c->app->log->debug("Build done, result $result");
            $c->app->ksb_state->{build_result} = $result;
        })->catch(sub {
            my @reason = @_;
            $c->app->log->error("Exception during build @reason");
        })->finally(sub {
            delete $c->app->ksb_state->{build_promise};
        });

        $c->render(text => $c->url_for('event_viewer')->to_abs->to_string);
    });

    $r->post('/shutdown' => sub {
        my $c = shift;

        # Shutdown the server once the transaction completes
        # by invoking ksb::Application::finish
        $c->tx->on(finish => sub {
            $c->app->ksb->finish(0);
        });

        $c->render(text => "Shutting down.\n", status => 200);
    });
}

1;
