package Cvs::Command::Base;

use strict;
use Cwd;
use IPC::Run;
use base qw(Class::Accessor);

Cvs::Command::Base->mk_accessors
(qw(
    cvsroot command args cvs need_workdir
    initial_context result go_into_workdir
));

sub new
{
    my($proto, $cvs, @args) = @_;
    my $class = ref $proto || $proto;
    my $self = {};
    bless($self, $class);
    $self->cvs($cvs) or
      die "this shouldn't happend";
    $self->go_into_workdir(1);
    $self->need_workdir(1);
    return ($self->init(@args))[0];
}

sub init
{
    return shift;
}

sub workdir {shift->cvs->workdir()}

sub run
{
    my($self) = @_;
    my $debug = $self->cvs->debug();

    #
    # Preparing environment and parameters
    #
    my $old_pwd;
    if($self->need_workdir())
    {
        # this can append when the Cvs object is created without a
        # working directory, and a sub-command that need it is called
        return $self->err_result('no such working directory')
          unless defined $self->workdir();

        # keep current working directory
        $old_pwd = cwd();

        if($self->go_into_workdir())
        {
            print STDERR "** Chdir to: ", $self->cvs->working_directory(), "\n"
              if $debug;
            chdir($self->cvs->working_directory());
        }
        else
        {
            print STDERR "** Chdir to: ", $self->cvs->pwd(), "\n"
              if $debug;
            chdir($self->cvs->pwd());
        }
    }

    # getting sub-command
    my $sub_command = $self->command();
    unless(defined $sub_command)
    {
        if(defined $self->result())
        {
            # this command don't need to be ran
            return $self->result();
        }
        else
        {
            return $self->err_result('empty result, it\'s a bug !')
        }
    }
    # getting cvsroot
    my $cvsroot = $self->cvsroot() || $self->cvs->cvsroot();
    return $self->err_result('no such cvsroot')
      unless(defined $cvsroot);

    # getting context, if none we spawn one
    my $context = $self->initial_context();
    unless(defined $context)
    {
        $context = $self->new_context();
        $self->initial_context($context);
    }

    # bind cvsroot handlers to the context
    $cvsroot->bind($self);
    # bind common handlers
    $self->bind();

    my @command = ('cvs');
    push @command, '-f', '-d', $cvsroot->cvsroot();
    push @command, '-t' if $debug > 1;
    push @command, $sub_command, $self->args();

    #
    # Starting command
    #
    print(STDERR join(' ', '>>', @command), "\n")
      if $debug;
    my($in, $out) = ('', '');
    # pty is needed for login sub-command (and maybe for something
    # else) because it open pty for prompting the password :(
    my $h = IPC::Run::harness(\@command, \$in, '>pty>', \$out, '2>&1');
    $h->start();
    $self->{harness} = $h;


    #
    # Parsing command result
    #
    # It's not trivial to parse the cvs output, because the output may
    # stall, and we never be sure that the command as finish, if a
    # line is complete or if the command is waiting for input (like a
    # password).
    my($last, $line, $match, $debugline);
    while(defined $context && $h->pump && length $out)
    {
        $match = 0;

        # flushing the send buffer
        $self->{data} = '';

        print STDERR "** new chunk\n"
          if $debug;

        while(defined $context && $out =~ /.*?(?:\r?\n|$)/g)
        {
            # the regex matches empty strings, so skip them
            # this happens when a chunk ends on a line boundary
            next unless length $&;

            $line = $&;

            # We receive output in chunks which don't necessarily end
            # at line boundaries. Therefore, we occasionally encounter
            # partial lines. We save them and then join them with the
            # next line, which is probably in the next chunk.
            if($last)
            {
                $line = $last . $line;
                undef $last;
            }
            if($line !~ /\n$/)
            {
                $last = $line;
                next;
            }

            $line =~ s/\r/\n/g;
            $line =~ s/\n+/\n/g;
            if($debug)
            {
                if($line =~ /^(?: |S)-> / or 
		  (defined $debugline and $debugline eq 'unterminated'))
                {
                    print STDERR $line;
                    # if the cvs debug line is truncated, try to not
                    # treat next parts as real cvs response component
                    $debugline = $line =~ /\n/ ? undef : 'unterminated';
                    undef $line;
                    next;
                }
                $debugline = $line;
                # make CR and LF visible
                $debugline =~ s/\r/\\r/g;
                $debugline =~ s/\n/\\n/g;
                print STDERR "<< $debugline\n";
            }

            # don't analyse empty lines, but $line have to be set
            next if $line =~ /^\n*$/;

            # Analysing the line: if a context is return, we replace
            # the current one with it to handling context
            # switching. If an undef value is returned, it's means
            # that no further analyse will be expected. The second
            # element is a boolean value which be true if the line
            # matched.
            ($context, $match) = $context->analyse($line);

            if(not $match)
            {
                print STDERR "** unmatched line: $debugline\n"
                  if $debug;
            }
        }
        # we don't want to parse several times the same thing
        $out = '';

        # check out if some input want be send
        if(length $self->{data})
        {
            $in = $self->{data};
            print STDERR ">> $in\n"
              if $debug;
            # wait for all input to go
            $h->pump_nb while length $in;
        }
    }

    my $rv = $h->finish() || $?;

    #
    # Restoring/cleaning-up environment
    #
    # exec cleanup codes if any
    if(defined $self->{cleanup})
    {
        print STDERR "** Do some cleanup tasks\n"
          if $debug;
        &$_ for @{$self->{cleanup}};
    }
    # back to the old working directory if needed
    chdir($old_pwd) if $self->need_workdir();

    #
    # Returning the result
    #
    my $result = $self->result;
    # should not happened
    return $self->err_result('empty result, it\'s a bug !')
      unless defined $result;
    $result->success($rv)
      unless defined $result->success();
    return $result;
}

sub err_result
{
    my($self, $msg) = @_;

    my $result = $self->result();
    unless(defined $result)
    {
        $result = new Cvs::Result::Base;
        $self->result($result);
    }

    $result->success(0);
    $result->error($msg);
    return $result;
}

sub push_cleanup
{
    my($self, $code) = @_;
    push @{$self->{cleanup}}, $code;
}

sub restart
{
    my($self) = @_;
    # restart command
    $self->{harness}->finish();
    $self->{harness}->start();
}

sub send
{
    my($self, $data) = @_;
    if(defined $data)
    {
        $self->{data} .= $data;
    }
}

sub bind
{
    my($self) = @_;

    my $context = $self->initial_context();
    $context->push_handler
    (
     qr/^cvs \[.* aborted\]: (.+)$/, sub
     {
         $self->err_result(shift->[1]);
         return $context->finish();
     }
    );
}

sub default_params
{
    my($self, %param) = @_;

    foreach(keys %param)
    {
        $self->{param}->{$_} ||= $param{$_};
    }
}

sub param
{
    my($self, $param) = @_;

    if(defined $param && ref $param eq 'HASH')
    {
        foreach(keys %$param)
        {
            $self->{param}->{$_} = $param->{$_}
              if exists $param->{$_};
        }
    }
    return $self->{param} || {};
}

sub push_arg
{
    my($self, @args) = @_;
    push @{$self->{args}}, @args;
}

sub args
{
    my($self) = @_;
    return @{$self->{args}||[]};
}

sub new_context
{
    my($self) = @_;
    return Cvs::Command::Context->new();
}

sub error
{
    my($self, @msg) = @_;
    my $package = ref $self || $self;
    no strict 'refs';
    if(@msg)
    {
        ${$package."::ERROR"} = join(' ', @msg);
        return undef;
    }
    else
    {
        return ${$package."::ERROR"};
    }
}

package Cvs::Command::Context;

use strict;
use constant LAST => -1;
use constant FINISH => -2;
use constant CONTINUE => -3;
use constant RESCAN => -4;

sub new
{
    my($proto) = @_;
    my $class = ref $proto || $proto;
    my $self = {};
    $self->{rules} = [];
    bless($self, $class);
    return $self;
}

sub last {return -1}
sub finish {return -2}
sub continue {return -3}
sub catched {return shift->{catched}}

sub rescan_with
{
    my($self, $context) = @_;

    if(defined $context)
    {
        $self->{rescan_context} = $context;
        return RESCAN;
    }
    return $self->{rescan_context};
}

sub push_handler
{
    my($self, $pattern, $code, @args) = @_;
    push @{$self->{rules}}, [$pattern, $code, @args];
}

sub analyse
{
    my($self, $line) = @_;

    my $match = 0;
    foreach (@{$self->{rules}})
    {
        my($pattern, $code, @args) = @$_;
        if(my @match = $line =~ /$pattern/)
        {
            $match++;
            my $rv = &$code([$line, @match], @args);
            if(defined $rv)
            {
                if(ref $rv eq 'Cvs::Command::Context')
                {
                    # switching to another area
                    return($rv, $match);
                }
                elsif($rv eq $self->continue)
                {
                    next;
                }
                elsif($rv eq $self->finish)
                {
                    return(undef, $match);
                }
                elsif($rv eq RESCAN)
                {
                    my $context = $self->rescan_with();
                    if(defined $context)
                    {
                        return $context->analyse($line);
                    }
                }
            }
            # if last (default behavior)
            return($self, $match);
        }
    }

    return($self, $match);
}

1;
=pod

=head1 LICENCE

This library is free software; you can redistribute it and/or modify
it under the terms of the GNU Lesser General Public License as
published by the Free Software Foundation; either version 2.1 of the
License, or (at your option) any later version.

This library is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
USA

=head1 COPYRIGHT

Copyright (C) 2003 - Olivier Poitrey

