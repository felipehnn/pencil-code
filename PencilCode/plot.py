#! /usr/bin/env python3
# Last Modification: $Id$
#=======================================================================
# plot.py
#
# Facilities for plotting the Pencil Code data.
#
# Chao-Chin Yang, 2013-10-22
#=======================================================================
def avg1d(datadir='./data', plane='xy', tsize=1024, var=None, **kwargs):
    """Plots the space-time diagram of a 1D average.

    Keyword Arguments:
        datadir
            Name of the data directory.
        plane
            Plane of the average.
        tsize
            Number of regular time intervals.
        var
            Name of the variable; if None, first variable is used.
        **kwargs
            Sent to matplotlib.pyplot.imshow.
    """
    # Chao-Chin Yang, 2013-10-29

    # Check the plane of the average.
    if plane == 'xy':
        xlabel = '$z$'
    elif plane == 'xz':
        xlabel = '$y$'
    elif plane == 'yz':
        xlabel = '$x$'
    else:
        raise ValueError("Keyword plane only accepts 'xy', 'xz', or 'yz'. ")

    # Read the data.
    print("Reading 1D averages...")
    from . import read
    time, avg = read.avg1d(datadir=datadir, plane=plane, verbose=False)

    # Default variable name.
    if var is None:
        var = avg.dtype.names[0]

    # Interpolate the time series.
    print("Interpolating", var, "...")
    import numpy as np
    from scipy.interpolate import interp1d
    tmin, tmax = np.min(time), np.max(time)
    ns = avg.shape[1]
    t = np.linspace(tmin, tmax, tsize)
    a = np.empty((tsize, ns))
    for j in range(ns):
        a[:,j] = interp1d(time, avg[var][:,j])(t)

    # Plot the space-time diagram.
    print("Plotting...")
    import matplotlib.pyplot as plt
    img = plt.imshow(a, origin='bottom', extent=[-0.5,0.5,tmin,tmax], aspect='auto', **kwargs)
    ax = plt.gca()
    ax.set_ylabel('$t$')
    ax.set_xlabel(xlabel)
    cb = plt.colorbar(img)
    cb.set_label(var)
    plt.show()

#=======================================================================
def time_series(datadir='./data', diagnostics='dt'):
    """Plots diagnostic variable(s) as a function of time.

    Keyword Arguments:
        datadir
            Name of the data directory.
        diagnostics
            (A list of) diagnostic variable(s).
    """
    # Chao-Chin Yang, 2013-10-22

    from . import read
    import matplotlib.pyplot as plt

    # Read the time series.
    ts = read.time_series(datadir=datadir)

    # Plot the diagnostics.
    if type(diagnostics) is list:
        for diag in diagnostics:
            plt.plot(ts.t, ts[diag])
    else:
        plt.plot(ts.t, ts[diagnostics])
    plt.xlabel('t')
    plt.ylabel(diagnostics)
    plt.show()
