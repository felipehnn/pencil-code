# param.py
#
# Read the parameters for the simulation.
# Requires: nl2python perl script (based on Wolfgang Dobler's nl2idl script).
# 14/02/20: default now load both init/run pars into Param(object), with
#           asdict and nest_dict also default. Only where parameter is present
#           in more than one module is it nested. Run parameter values replace
#           conflicting init values.
#
# Authors:
# J. Oishi (joishi@amnh.org).
# S. Candelaresi (iomsn1@gmail.com)
# F. A. Gent (fred.gent.ncl@gmail.com)
"""
Contains the parameters of the simulation.
"""


def param(*args, **kwargs):
    """
    Read Pencil Code simulation parameters.
    Requires: nl2python perl script (based on Wolfgang Dobler's nl2idl script).

    call signature:

    read(datadir='data', param1=False, param2=False, quiet=True,
         conflicts_quiet=False, asdict=True, nest_dict=True, append_units=True)


    Keyword arguments:

    *datadir*:
      Directory where the data is stored.

    *param1*:
      Selects the set of parameters only from start.

    *param2*:
      Selects the set of parameters only from run.

    *quiet*
      Flag for switching of output.

    *conflicts_quiet*
      Flag for switching off printing duplicate labels.

    *asdict*
      Reads parameters as dictionary.

    *nest_dict*
      Reads parameters as nested dictionary.

    *append_units*
      Derives dimensional units from standard code units.
    """

    param_tmp = Param()
    param_tmp.read(*args, **kwargs)
    return param_tmp


class Param(object):
    """
    Param -- holds the simulation parameters.
    """

    def __init__(self):
        """
        Fill members with default values.
        """

        self.keys = []


    def read(self, datadir='data', param1=False, param2=False, quiet=True,
             conflicts_quiet=False,
             asdict=True, nest_dict=True, append_units=True):
        """
        Read Pencil Code simulation parameters.
        Requires: nl2python perl script (based on Wolfgang Dobler's nl2idl script).

        call signature:

        read(datadir='data', param1=False, param2=False, quiet=True,
             conflicts_quiet=False, asdict=True, nest_dict=True,
             append_units=True)

        Keyword arguments:

        *datadir*:
          Directory where the data is stored.

        *param1*:
          Selects the set of parameters only from start.

        *param2*:
          Selects the set of parameters only from run.

        *quiet*
          Flag for switching off output.

        *conflicts_quiet*
          Flag for switching off printing duplicate labels.

        *asdict*
          Reads parameters as dictionary.

        *nest_dict*
          Reads parameters as nested dictionary.

        *append_units*
          Derives dimensional units from standard code units.
        """
        import os
        from os.path import join, exists

        datadir = os.path.expanduser(datadir)

        #Collect files to be read into a list
        files = []
        if param1:
            files.append(join(datadir, 'param.nml'))
        elif param2:
            files.append(join(datadir, 'param2.nml'))
        else:
            files.append(join(datadir, 'param.nml'))
            if exists(join(datadir, 'param2.nml')):
                files.append(join(datadir, 'param2.nml'))

        # Verify path of files in list.
        for filen in files:
            if not os.path.exists(filen):
                print("read.param: no such file {0}.".format(filen))
                raise ValueError

        # Read the parameters into a dictionary.
        param_list = dict()
        # Construct object from dictionary with Python
        if asdict:
            super_name_list = list()
            name_list = list()
            param_conflicts = dict()
            # Nesting parameters with same name under module attributes
            if nest_dict:
                for filen in files:
                    param_list, param_conflicts, name_list, super_name_list = \
                                self.__read_nml(param_list, filen,
                                                param_conflicts, name_list, super_name_list, nest=True)
            # Parameters with same name will be written by last value
            else:
                for filen in files:
                    param_list, param_conflicts, name_list, super_name_list = \
                                self.__read_nml(param_list, filen,
                                                param_conflicts, name_list, super_name_list)
            if not param_conflicts:
                subkey_list = list()
                for super_name in super_name_list:
                    if super_name in param_conflicts.keys():
                        for subkey in param_conflicts[super_name].keys():
                            subkey_list.append(subkey)
                for super_name in super_name_list:
                    if not super_name in param_conflicts.keys():
                        if param_list.__contains__(super_name):
                            param_list.__delitem__(super_name)
                        super_name_list.remove(super_name)
                for super_name in super_name_list:
                    for key in name_list:
                        if not key in subkey_list:
                            if key in param_list[super_name].keys():
                                param_list[super_name].__delitem__(key)
                for key in name_list:
                    if key in param_list.keys() and key in subkey_list:
                        param_list.__delitem__(key)

            # If nesting occurs report conflicts and record nests to retain
            if not param_conflicts:
                for key in param_conflicts.keys():
                    for subkey in param_conflicts[key].keys():
                        if not conflicts_quiet:
                            print(subkey, 'as', param_conflicts[key][subkey][0],
                                  'in', key, 'conflicts with',
                                  param_conflicts[key][subkey][2], 'in',
                                  param_conflicts[key][subkey][1])
            # Create object container for nested contents
            class Foo(object):
                pass
            # Construct class Params object attributes
            for key in param_list.keys():
                # Nest only parameters with name conflicts
                if key in super_name_list:
                    ext_object = Foo()
                    setattr(self, key, ext_object)
                    for subkey in param_list[key].keys():
                        if not quiet:
                            print(subkey, 'is nested under', key)
                        setattr(ext_object, subkey, param_list[key][subkey])
                else:
                    # Unique parameters saved unnested
                    setattr(self, key, param_list[key])
            if not quiet:
                print(param_list)
        # Construct object by calling external perl script
        else:
            # Execute output of nl2python script.
            for filen in files:
                cmd = 'nl2python ' + filen
                script = os.popen(cmd).read()
                if not quiet:
                    print(script)
                if script:
                    # This import is needed to execute the script.
                    import numpy
                    # TODO: Do this without calling a shell command.
                    # Done: via asdict
                    exec(script.replace("\n    ", "\nself.")[198:])
                    del(numpy)
                else:
                    print("Param.read: nl2python returned nothing!"+
                          " Is $PENCIL_HOME/bin in the path?")
                    return -1

        if append_units:
            setattr(self, 'unit_time', self.unit_length/self.unit_velocity)
            setattr(self, 'unit_mass', self.unit_density*self.unit_length**3)
            setattr(self, 'unit_flux', self.unit_mass/self.unit_time**3)
            setattr(self, 'unit_energy', self.unit_mass*self.unit_velocity**2)
            setattr(self, 'unit_energy_density',
                    self.unit_density*self.unit_velocity**2)
            setattr(self, 'unit_entropy',
                    self.unit_velocity**2/self.unit_temperature)
            if hasattr(param, 'mu0'):
                setattr(self, 'unit_current',
                        self.unit_magnetic*self.unit_length/self.mu0)

        return 0


    def __param_formatter(self, string_part):
        """
        Formats the parameters from the files.

        call signature:

        __param_formatter(self, string_part)

        Keyword arguments:

        *string_part*:
          Part of the string to be formatted.
        """

        import re

        string_part = re.sub(" ", "", string_part)
        if string_part == "T":
            return True
        if string_part == "F":
            return False
        try:
            if "." in string_part:
                return float(string_part)
            return int(string_part)
        except:
            return re.sub("'", "", string_part)


    def __tuple_catch(self, string):
        """
        Catches name - value tuples in a string.

        call signature:

        __tuple_catch(self, string)

        Keyword arguments:

        *string*:
          String containing the name - value tuple.
        """

        if "(" in string:
            string = string.replace("(", "").replace(")", "").split(",")
            for j in range(len(string)):
                string[j] = self.__param_formatter(string[j])
            return tuple(string)
        return self.__param_formatter(string)


    def __read_nml(self, params, file_name, param_conflicts, name_list,
                   super_name_list, nest=False):
        """
        Reads in F90 namelist as dictionary object

        call signature:

        __read_nml(self, file_name, nest=False)

        Keyword arguments:

        *file_name*:
          Name of the file.

        *nest*
          For nested dictionaries.
        """

        import re

        r = re.compile(r'(?:[^,(]|\([^)]*\))+')

        # Contain the nested parameters to be retained
        # Contain the nest names for each parameter set
        for rawline in open(file_name):
            if ',' in rawline[1]:
                rawline = lastrawline+rawline
            if ' ' in rawline[1]:
                rawline = lastrawline+rawline
            if "'" in rawline[1]:
                rawline = lastrawline+rawline
            lastrawline = rawline
            line = rawline.rstrip('\n')
            if line[1] == "&" or line[0] == "&":
                super_name = line[2:].lower().rsplit('_pars')[0].rsplit('_init')[0].rsplit('_run')[0]
                if nest:
                    if not params.__contains__(super_name):
                        params[super_name] = dict()
                        super_name_list.append(super_name)
            else:
                line = re.sub("^ ", "", line)
                if line != "/":
                    split = re.split("=", line)
                    name = re.sub(" ", "", split[0].lower())
                    value = split[1]
                    parts = r.findall(value)
                    value = []
                    for i in range(len(parts)):
                        if "*" in parts[i]:
                            s = parts[i].split("*")
                            for j in range(int(s[0])):
                                value += [self.__tuple_catch(s[1])]
                        else:
                            value += [self.__tuple_catch(parts[i])]
                    if len(value) == 1:
                        value = value[0]
                    params[name] = value
                    name_list.append(name)
                    if nest:
                        # Save all parameters nested and unnested
                        if not super_name in ('run', 'init'):
                            params[super_name][name] = value
        # If name conflict exists remove unnested copies
        if len(super_name_list) > 0:
            if 'run' in super_name_list: super_name_list.remove('run')
            if 'init' in super_name_list: super_name_list.remove('init')
            for super_name in super_name_list:
                for alt_name in super_name_list:
                    for name in params[super_name].keys():
                        if name in params[alt_name].keys():
                            if not params[alt_name][name] ==\
                                   params[super_name][name]:
                                if not super_name in param_conflicts.keys():
                                    param_conflicts[super_name] = dict()
                                param_conflicts[super_name][name] = (
                                    params[super_name][name],
                                    alt_name,
                                    params[alt_name][name])

        return params, param_conflicts, name_list, super_name_list

