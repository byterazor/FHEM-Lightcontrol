package main;
use strict;
use warnings;
use POSIX;
use Data::Dumper;


my $module_name="LightControl";
my $VERSION    = '0.0.1';



# wrapper for logging
sub LightControl_Log
{
  my $verbosity=shift;
  my $msg=shift;

  Log3 $module_name, $verbosity, $module_name . ":" . $msg;
}

sub LightControl_Parse_Params
{
    my $argsString=shift;
    my %params;

    foreach my $arg (split /[\s\t]/,$argsString)
    {
        if (!defined($params{name}))
        {
            $params{name}=$arg;
        }
        elsif(!defined($params{type}))
        {
            $params{type}=$arg;
        }
        elsif( $arg =~ /^([a-zA-Z0-9\-_]+)=([a-zA-Z0-9\-_]+)$/)
        {
            if (!defined($params{$1}))
            {
                my @array;
                $params{$1}=\@array;
            }
            push(@{$params{$1}},$2);
        }
        elsif( $arg =~ /^([a-zA-Z0-9\-_]+)=\'([a-zA-Z0-9\-_\s\"]+)\'$/)
        {
            if (!defined($params{$1}))
            {
                my @array;
                $params{$1}=\@array;
            }
            push(@{$params{$1}},$2);
        }
        elsif( $arg =~ /^([a-zA-Z0-9\-_]+)=\"([a-zA-Z0-9\-_\s]+)\"$/)
        {
            if (!defined($params{$1}))
            {
                my @array;
                $params{$1}=\@array;
            }
            push(@{$params{$1}},$2);
        }
    }

    return \%params;
}

#
# Initialize the callback function of the module
#
sub LightControl_Initialize
{
    my ($hash) = @_;
    $hash->{DefFn}      = 'LightControl_Define';
    $hash->{ReadFn}     = undef;
    $hash->{ReadyFn}    = undef;
    $hash->{NotifyFn}   = 'LightControl_Notify';
    $hash->{UndefFn}    = undef;
    $hash->{DeleteFn}   = undef;
    $hash->{SetFn}      = undef;
    $hash->{GetFn}      = undef;
    $hash->{AttrFn}     = undef;
    $hash->{AttrList}   =
                            "startScene " .
                            "onEventRegEx " .
                            "toggleEventRegEx " .
                            "offEventRegEx " .
                            "HighScene " .
                            "LowScene " .
                            "lowSceneEventRegEx " .
                            "highSceneEventRegEx " .
                            $readingFnAttributes;
}


sub LightControl_Define
{
    my ($hash, $define) = @_;

    # ensure we have something to parse
    if (!$define)
    {
      warn("$module_name: no module definition provided");
      LightControl_Log(1,"no module definition provided");
      return;
    }

    # parse parameters into array and hash
    my $params=LightControl_Parse_Params($define);
    
    my $name                = $params->{name};

    # verify that $name is a valid and good fhem name
    if (!goodDeviceName($name))
    {
        return "$name is not a good definition name";
    }

    $hash->{NAME}             = $name;
    $hash->{STATE}            = "initializing";

    if (!defined($params->{lamp}))
    {
        return "at least one lamp definition is required";
    }
    $hash->{helper}->{lamp} = $params->{lamp}->[0];

    if (!defined($params->{switch}))
    {
        return "at least one switch definition is required";
    }
    $hash->{helper}->{switch} = $params->{switch};

    if (!defined($params->{scene}))
    {
        return "one scene definition is required";
    }
    $hash->{helper}->{scene} = $params->{scene}->[0];

    my @devs = (@{$params->{switch}});

    my $devspec="global";
    foreach my $dev (@devs)
    {
         if (!IsDevice($dev))
         {
             return "$dev is not a valid device name";
         }
    
         $devspec .= ",$dev";
    }

    LightControl_Log(1, "created devspec of \"$devspec\"");

    setNotifyDev($hash,$devspec);

    return;
}

sub LightControl_Init
{
    my $hash = shift;

    my $value = ReadingsVal($hash->{helper}->{scene}, "Scenes", "");
    LightControl_Log(1,$value);
    if ($value =~ /\S+/)
    {
        my @scenes = split/,/,$value;
        $hash->{helper}->{startSceneDefault} =$scenes[0];
    }

    $hash->{STATE} = "initialized";
}

sub LightControl_Notify
{
    my ($hash, $dev_hash) = @_;
    my $name = $hash->{NAME};

    return "" if(IsDisabled($name));

    if ($dev_hash->{NAME} eq "global")
    {
        my $events = deviceEvents($dev_hash,1);
        return if( !$events );
        foreach my $event (@{$events}) 
        {
            $event = "" if(!defined($event));

            if ($event eq "INITIALIZED")
            {
                LightControl_Init($hash);
            }
        }
    }
    else 
    {
        my $events = deviceEvents($dev_hash,1);
        return if( !$events );

        # fetch all used attributes
        my $onEvent         = AttrVal($hash->{NAME},"onEventRegEx","action:.on-press");
        my $reOnEvent       = qr/$onEvent/;
        my $offEvent        = AttrVal($hash->{NAME},"offEventRegEx","action:.off-press");
        my $reOffEvent      = qr/$offEvent/;
        my $toggleEvent     = AttrVal($hash->{NAME},"toggleEventRegEx","action:.on-press");
        my $reToggleEvent   = qr/$toggleEvent/;
        my $highEvent       = AttrVal($hash->{NAME},"highSceneEventRegEx",undef);
        my $reHighEvent;
        if ($highEvent)
        {
            $reHighEvent=qr($highEvent);
        } 
        my $lowEvent        = AttrVal($hash->{NAME},"lowSceneEventRegEx",undef);
        my $reLowEvent;
        if ($lowEvent) 
        {
           $reLowEvent = qr($lowEvent);
        }

        foreach my $event (@{$events}) 
        {
            $event = "" if(!defined($event));

            if ($event=~$reToggleEvent)
            {
                LightControl_Log(1, "toggle");    
                if (ReadingsVal($hash->{helper}->{lamp},"state","") eq "on")
                {
                    fhem( "set " . $hash->{helper}->{scene} . " nextScene");
                }
                else 
                {
                    my $startScene = AttrVal($hash->{NAME},"startScene",$hash->{helper}->{startSceneDefault});
                    LightControl_Log(1, $hash->{NAME}. " - startScene: $startScene");
                    fhem("set " . $hash->{helper}->{scene} . " scene " . $startScene);
                }
            }

            if ($event =~ $reOnEvent)
            {
                LightControl_Log(1, "on"); 
                fhem( "set " . $hash->{helper}->{lamp} . " on");
            }

            if ($event=~ $reOffEvent)
            {
                LightControl_Log(1, "off"); 
                fhem( "set " . $hash->{helper}->{lamp} . " off");
            }

            if ($event=~ $reHighEvent)
            {
                my $scene = AttrVal($hash->{NAME},"HighScene",undef);
                LightControl_Log(1, "Highscene: ". $scene);
                if ($scene)
                {
                    fhem("set " . $hash->{helper}->{scene} . " scene " . $scene);
                }
            }
            
            if ($event=~ $reLowEvent)
            {
                my $scene = AttrVal($hash->{NAME},"LowScene",undef);
                LightControl_Log(1, "Lowscene: ". $scene);
                if ($scene)
                {
                    fhem("set " . $hash->{helper}->{scene} . " scene " . $scene);
                }
            }

        }
    }
}


1;