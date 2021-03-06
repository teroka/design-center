#
# configure/activate command
#
# CFEngine AS, October 2012
#
# Time-stamp: <2013-05-26 00:54:13 a10022>

use Term::ANSIColor qw(:constants);

use Util;
use Term::ReadLine;

######################################################################

%COMMANDS =
 (
  'define' =>
  [
   [
    'define params SKETCH [ PARAMSET [FILE.json] ]',
    'Create a new parameter set for SKETCH named PARAMSET using the parameters from FILE.json, or interactively if the file is ommitted. If PARAMSET is omitted, a name is automatically generated.',
    'params\s+(\S+)\s*(?:\s+(\S+)(?:\s+(\S+))?)?',
    'define_params'
   ],
  ]
 );

######################################################################

sub command_define_params {
    my $sketch = shift;
    my $paramset = shift;
    my $file = shift;

    my $defs = main::get_definitions;
    if ($paramset && exists($defs->{$paramset}))
    {
        Util::error("Error: A parameter set named '$paramset' already exists, please use a different name.\n");
        return;
    }
    my $allsk = main::get_all_sketches;
    unless (exists($allsk->{$sketch}))
    {
        Util::error("Error: Sketch '$sketch' does not exist in any of the repositories I know about.\n");
        return;
    }
    if ($file)
    {
        unless ($paramset)
        {
            Util::error("Error: PARAMSET name not provided, but needed to load parameters from a file.\n");
            return;
        }
        my $load = $Config{dcapi}->load($file);
        unless (defined $load)
        {
            Util::error("Error: Could not load $p: $!");
            return;
        }
        Util::message("Defining parameter set '$paramset' with data loaded from '$file'.\n");
        my ($success, $result) = main::api_interaction({define => 
                                                        {
                                                         $paramset => $load,
                                                        }});
        return unless $success;
        Util::success("Parameter set $paramset successfully defined.\n");
    }
    else
    {
        interactive_config($paramset, $defs, $sketch, $allsk->{$sketch});
    }
}

sub interactive_config {
    my ($paramset, $defs, $sketchname, $sketchjson) = @_;
    my $meta = Util::hashref_search($sketchjson, qw/metadata/);
    my $api = Util::hashref_search($sketchjson, qw/api/);
    my @bundles=sort keys %$api;
    my $numbundles = scalar(@bundles);
    my $bundle = undef;
    if ($numbundles == 0)
    {
        Util::error("Sketch $sketchname does not have any configurable parameters!");
        return;
    }
    if ($numbundles > 1)
    {
        my $choice = query_bundle($api);
        if ($choice < 0)
        {
            Util::message("Cancelling configuration.\n");
            return;
        }
        $bundle = $bundles[$choice];
    }
    else
    {
        $bundle = $bundles[0];
    }
    if (!$paramset)
    {
        # Generate a name for the new paramset
        my $base = "$sketchname-$bundle";
        my $i=0;
        do
        {
            $paramset = sprintf("$base-%03d", $i);
            $i++;
        } while (exists($defs->{$paramset}));
        my $newname = single_prompt("Please enter a name for the new parameter set (default: $paramset): ");
        $paramset = $newname || $paramset;
    }
    Util::message("Querying configuration for parameter set '$paramset' for bundle '$bundle'.\n");
    my $data = query_and_validate($api, $bundle);
    if (!$data)
    {
        Util::message("Cancelling configuration.\n");
        return;
    }
    Util::message("Defining parameter set '$paramset' with the entered data.\n");
    my ($success, $result) = main::api_interaction({define => 
                                                    {
                                                     $paramset => { $sketchname => $data },
                                                    }});
    return unless $success;
    Util::success("Parameter set $paramset successfully defined.\n");
}

sub single_prompt {
    my $msg=shift || "> ";
    my $input = Term::ReadLine->new("$msg");
    my @hist = $input->GetHistory();
    $input->clear_history;
    my $str = $input->readline($msg);
    $input->SetHistory(@hist);
    return $str;
}

sub query_bundle {
    my $api=shift;
    my @bundles=();
    foreach my $bundle (sort keys %$api)
    {
        my $bundlestr = "$bundle(" .
         join(", ",
              map { $_->{name} }
              grep { $_->{type} !~ /^(metadata|environment|bundle_options|return)$/ }
              @{$api->{$bundle} } ) .
               ")";
        push @bundles, $bundlestr;
    }
    my $numbundles=scalar(@bundles);
    Util::message("This sketch has multiple accessible bundles.\n");
    for my $i (1..$numbundles)
    {
        print "    ".YELLOW.$i.RESET.". ".$bundles[$i-1]."\n";
    }
    my $which=undef;
    my $valid=undef;
    do
    {
        $which=single_prompt("Which one do you want to configure? (1-$numbundles, Enter to cancel) ");
        $valid=undef;
        if ($which eq "")
        {
            return -1;
        }
        if ($which>=1 && $which <=$numbundles)
        {
            $valid=1;
        }
        else
        {
            Util::error("Invalid entry. Please retry.\n");
        }
    } until ($valid);
    return $which-1;
}

sub query_and_validate {
    my $api = shift;
    my $bundle = shift;
    my $data = {};

    unless (exists($api->{$bundle}))
    {
        Util::error("Internal error: cannot find API for bundle '$bundle'.\n");
        return undef;
    }

    # Set up input prompt
    my $input = Term::ReadLine->new('interactive-config');
    my @oldhist = $input->GetHistory();
    $input->clear_history();

    my $bapi = $api->{$bundle};
    my $value;
    my $valid;
    foreach my $p (@$bapi)
    {
        next if $p->{type} =~ /^(metadata|environment|bundle_options|return)$/;
        do
        {
            $valid = undef;
            $value = prompt_param($p, $input);
            unless (defined($value)) {
                $input->SetHistory(@oldhist);
                return undef;
            }
            if (exists($p->{validation}))
            {
                $valid = validate_param($p, $value);
            }
            else
            {
                $valid = 1;
            }
        } while (!$valid);
        $data->{$p->{name}} = $value;
    }
    $input->SetHistory(@oldhist);
    return $data;
}

sub validate_value {
    my $val = shift;
    my $data = shift;
    my ($success, $result) = main::api_interaction({
                                                    validate =>
                                                    {
                                                     validation => $val,
                                                     data => $data,
                                                    }
                                                   });
    return $success;
}

sub validate_param {
    my $p = shift;
    my $value = shift;

    if ($p->{validation} && $value ne '?')
    {
        return validate_value($p->{validation}, $value);
    }
    else
    {
        # If no validation, always return true
        return 1;
    }
}

sub print_validation_help {
    my $val = shift;
    if (!$val)
    {
        Util::warning("This parameter has no validation specified.\n");
    }
    else
    {
        Parser::command_list_vals('-v', "^$val\$", "This parameter needs to validate as a $val:");
    }
}

sub prompt_param {
    my $p = shift;
    my $input = shift;

    my $type = $p->{type};
    my $name = $p->{name};
    my $desc = $p->{description};
    my $ex   = $p->{example};
    my $val  = $p->{validation};

    my $parenstr = "";
    my $exstr = "for example '$ex'" if $ex;
    $parenstr = " (".join(", ", $desc || "", $exstr || "").")" if ($desc || $ex);

    my $ret = undef;
    Util::message("Please enter parameter $name$parenstr.\n");
    Util::message(validationstr($val)."\n") if $val;
    Util::message("  (enter STOP to cancel)\n");
  PROMPT_PARAM:
    $ret = input_param($p, $input);
    if ($ret && $ret eq '?')
    {
        print_validation_help($val);
        goto PROMPT_PARAM;
    }
    return undef if !$ret || ($ret eq 'STOP');
    return $ret;
}

sub input_scalar {
    my $input = shift;
    my $prompt = shift || "> ";
    my $def = shift;
    my $val = shift;
    my $valid = undef;
    my $data = undef;
    do
    {
        # Default value is included in the prompt
        $data = $input->readline($prompt.($def? "[$def]" : "").": ", $def);
        return $data unless $data;
        # STOP ends data input
        if ($data eq 'STOP')
        {
            return undef;
        }
        if ($val && $data ne '?')
        {
            $valid = validate_value($val, $data);
        }
        else
        {
            $valid = 1;
        }
    } while (!$valid);

    return $data;
}

sub input_param {
    my $p = shift;
    my $input = shift;
    my $prompt = shift;

    my $type = $p->{type};
    my $name = $p->{name};
    my $desc = $p->{description};
    my $ex   = $p->{example};
    my $val  = $p->{validation};
    my $def  = $p->{default} || "";
    my $vals = main::get_validations;
    my $valstruct = $vals->{$val||""};

    my $valid = undef;
    my $data = undef;
    my $elem = undef;
  VALIDATE_PARAM: do
    {
        if ($type eq 'list')
        {
            my @olddata=();
            @olddata = @$def if $def;
            if ($valstruct && $valstruct->{sequence})
            {
                my @seq_elems = @{$valstruct->{sequence}};
                for my $e (@seq_elems)
                {
                    my $def_next = shift @olddata;
                    my $e_val = { validation => $e };
                  INPUT_SCALAR_IN_SEQUENCE:
                    $elem = input_scalar($input, "Next element in sequence ($e)", $def_next, $e_val);
                    return undef unless defined($elem);
                    if ($elem eq '?')
                    {
                        print_validation_help($val);
                        goto INPUT_SCALAR_IN_SEQUENCE;
                    }
                    push @$data, $elem if $elem;
                }
                if (validate_value($val, $data))
                {
                    $valid = 1;
                }
                else
                {
                    Util::error("Invalid data. Please try again.\n");
                    @olddata = @$data;
                    next VALIDATE_PARAM;
                }
            }
            else
            {
                $elem = undef;
                $data = [];
                $valid = 1; # empty lists are valid
                do
                {
                    my $def_next = shift @olddata;
                  INPUT_SCALAR_IN_LIST:
                    $elem = input_scalar($input, "Next element (Enter to finish)", $def_next, undef);
                    return undef unless defined($elem);
                    if ($elem)
                    {
                        if ($elem eq '?')
                        {
                            print_validation_help($val);
                            goto INPUT_SCALAR_IN_LIST;
                        }
                        else
                        {
                            push @$data, $elem;
                            if ($val && !validate_value($val, $data))
                            {
                                Util::error("Invalid data. Please try again.\n");
                                pop @$data;
                                goto INPUT_SCALAR_IN_LIST;
                            }
                            else
                            {
                                $valid = 1;
                            }
                        }
                    }
                } while ($elem);
            }
        }
        elsif ($type eq 'array')
        {
            my %olddata = ();
            %olddata = %$def if $def;
            my @oldkeys = sort keys %olddata;
            $elem = undef;
            $data = {};
            $valid = 1; # empty arrays are valid
            do
            {
                my $def_next_k = shift @oldkeys;
              INPUT_KEY_IN_ARRAY:
                $elem = input_scalar($input, "Next key (Enter to finish)", $def_next_k, undef);
                return undef unless defined($elem);
                if ($elem)
                {
                    if ($elem eq '?')
                    {
                        print_validation_help($val);
                        goto INPUT_KEY_IN_ARRAY;
                    }
                    else
                    {
                        my $elem_v = input_scalar($input, "$name\[$elem\]", $olddata{$elem}, undef);
                        return undef unless defined($elem_v);
                        if ($elem eq '?')
                        {
                            print_validation_help($val);
                            goto INPUT_KEY_IN_ARRAY;
                        }
                        $data->{$elem} = $elem_v;
                        if ($val && !validate_value($val, $data))
                        {
                            Util::error("Invalid data. Please try again.\n");
                            pop @$data;
                            goto INPUT_KEY_IN_ARRAY;
                        }
                        else
                        {
                            $valid = 1;
                        }
                    }
                }
            } while ($elem);
        }
        elsif ($type eq 'string')
        {
            # Call without validation (last param "undef") because this value
            # gets validates upon return.
            $data = input_scalar($input, ($prompt ? $prompt : "$name "), $def, undef);
            # input_scalar() only returns with valid data or undef for STOP
            $valid = 1;
        }
        elsif ($type eq 'boolean')
        {
            my $str = input_scalar($input, ($prompt ? $prompt : "$name "), $def, undef);
            $data = ($str =~ /^(yes|true|1|on)$/i) ? 1 : undef;
            $valid = $str =~ /^(yes|true|1|on|no|false|0|off)$/i;
        }
    } while (!$valid);
    return $data;
}

sub validation_description {
    my $val = shift;
    if ($val->{description})
    {
        return $val->{description};
    }
    elsif ($val->{derived})
    {
        return validation_description($val->{derived});
    }
    elsif ($val->{list})
    {
        return "list of ".join(" or ", map { validation_description($_) } @{$val->{list}});
    }
    elsif ($val->{array_k})
    {
        return "array of [ " .
         join(" or ", map { validation_description($_) } @{$val->{array_k}}) .
         ", " .
         join(" or ", map { validation_description($_) } @{$val->{array_v}}) .
         " ]";
    }
    elsif ($val->{sequence})
    {
        return "sequence of [ ".
         join(" or ", map { validation_description($_) } @{$val->{sequence}}) .
         " ]";
    }
}

sub validationstr {
    my $valname=shift;

    return "" unless $valname;

    my $vals = main::get_validations;
    my $val = $vals->{$valname};
    if ($val)
    {
        if ($val->{description})
        {
            return "This parameter must validate as a ".$val->{description}." (please enter ? at the prompt to see the full definition of this validation).";
        }
        else
        {
            return "This parameter must be a $valname (please enter ? at the prompt to see the full definition of this validation).";
        }
    }
    else
    {
        if ($valname)
        {
            return "This parameter is defined as a '$valname', but I don't have a validation by that name. I will treat it as a scalar and accept anything you type.";
        }
    }
}

 sub query_and_validate_old {
     my $var = shift;
     my $input = shift;
     my $prev = shift;
     my $name = $var->{name};
     my $type = $var->{type};
     my $def  = $prev || (DesignCenter::JSON::recurse_print($var->{default}, undef, 1))[0]->{value};
     my $value;
     my $valid;

     # List values
     if ($type =~ m/^LIST\((.+)\)$/)
     {
         my $subtype = $1;
         Util::output(GREEN."\nParameter '$name' must be a list of $subtype.\n".RESET);
         Util::output("Please enter each value in turn, empty to finish.\n");
         my $val = [];
         while (1)
         {
             do {
                 $valid = 0;
                 my $elem = $input->readline("Please enter next value: ");
                 if ($elem eq 'STOP')
                 {
                     return (undef, 1);
                 }
                 elsif ($elem eq '')
                 {
                     # Validate the whole thing
                     $valid = DesignCenter::Sketch::validate($val, $type);
                     return ($val, 0) if $valid;
                     Util::error "List validation failed. Resetting, please reenter all the values.\n";
                     $val = [];
                 }
                 else
                 {
                     $valid = DesignCenter::Sketch::validate($elem, $subtype);
                     if ($valid)
                     {
                         push @$val, $elem;
                     }
                     else
                     {
                         Util::warning "Invalid value, please reenter it.\n";
                     }
                 }
             } until ($valid);
         }
     }
     elsif ($type =~ m/^(KV)?ARRAY\(/)
     {
         Util::output(GREEN."\nParameter '$name' must be an array.\n".RESET);
         Util::output("Please enter each key and value in turn, empty key to finish.\n");
         my $val = {};
         my @keys = ();
         if ($def && ref($def) eq 'HASH')
         {
             @keys = sort keys %$def;
         }
         while (1)
         {
             do {
                 $valid = 0;
                 my $oldkey = shift @keys;
                 my $k = $input->readline("Please enter next key".
                                          ($oldkey ? " [$oldkey]: " : ": "), $oldkey);
                 if ($k eq 'STOP')
                 {
                     return (undef, 1);
                 }
                 elsif ($k eq '')
                 {
                     # Validate the whole thing
                     $valid = DesignCenter::Sketch::validate($val, $type);
                     return ($val, 0) if $valid;
                     Util::error "Array validation failed. Resetting, please reenter all the values.\n";
                     $val = {};
                 }
                 else
                 {
                     my $oldval = $def->{$k};
                     my $v = $input->readline("Please enter value for $name\[$k\]".
                                              ($oldval ? " [$oldval]: " : ": "), $oldval);
                     if ($k eq 'STOP')
                     {
                         return (undef, 1);
                     }
                     else
                     {
                         # No validation happens here. Should probably be fixed.
                         $val->{$k} = $v;
                     }
                 }
             } until ($valid);
         }
     }
     else
     {
         # Scalar values are the easiest
         Util::output(GREEN."\nParameter '$name' must be a $type.\n".RESET);
         do {
             $valid=0;
             my $stop=0;
             $value = $input->readline("Please enter $name".
                                       ($def ? " [$def]: ":": "), $def);
             if ($value eq 'STOP')
             {
                 return (undef, 1);
             }
             $valid = DesignCenter::Sketch::validate($value, $type);
             Util::warning "Invalid value, please reenter it.\n" unless $valid;
         } until ($valid);
     }
     return ($value, undef);
 }

sub command_configure_interactive {
    my $name = shift;
    my ($sketch, $num) = split(/#/, $name);

    my $skobj = find_sketch($sketch) || return;

    foreach my $repo (@{DesignCenter::Config->repolist})
    {
        my $contents = CFSketch::repo_get_contents($repo);
        if (exists $contents->{$sketch})
        {
            my $data = $contents->{$sketch};
            my $if = $data->{interface};

            my $entry_point = DesignCenter::Sketch::verify_entry_point($sketch, $data);

            if ($entry_point)
            {
                my $varlist = $entry_point->{varlist};
                my $params = {};
                if ($num)
                {
                    my @activations = @{$skobj->_activations};
                    my $count = $skobj->num_instances;
                    if ($num > $count)
                    {
                        Util::warning "Configuration instance #$num does not exist.\n";
                        return;
                    }
                    $params = $activations[$num-1];
                }
                Parser::_message("Entering interactive configuration for sketch $sketch.\nPlease enter the requested parameters (enter STOP to abort):\n");
                my $input = Term::ReadLine->new("cf-sketch-interactive");
                foreach my $var (@$varlist)
                {
                    # These are internal parameters, we skip them
                    if ($var->{name} =~ /^(prefix|class_prefix|canon_prefix)$/)
                    {
                        $params->{$var->{name}} = $params->{$var->{name}} || $var->{default};
                        next;
                    }
                    my ($value, $stop) = query_and_validate($var, $input, $params->{$var->{name}});
                    if ($stop)
                    {
                        Util::warning "Interrupting sketch configuration.\n";
                        return;
                    }
                    $params->{$var->{name}} = $value;
                }
                # Parameter input complete, let's activate it
                unless (DesignCenter::Sketch::install_config($sketch, $params, $num?($num-1):undef)) {
                    Util::error "Error installing the sketch configuration.\n";
                    return;
                }
            }
            else
            {
                Util::error "Can't configure $sketch: missing entry point - it's probably a library-only sketch.";
                return;
            }
        }
        else
        {
            Util::error "I could not find sketch $sketch in the repositories. Is the name correct?\n";
            return;
        }
    }

}
