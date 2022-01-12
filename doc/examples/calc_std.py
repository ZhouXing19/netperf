#!/usr/bin/python3

# Copyright 2022 The Cockroach Authors.
#
# Use of this software is governed by the Business Source License
# included in the file licenses/BSL.txt.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0, included in the file
# licenses/APL.txt.

# This python script is used to determine the lastest 3 aggregate throughput has
# converged. It's given three float numbers as the lastest three throughput result.
# If the series is not strictly growing, we determine the throughput has converged.
# If the series is strictly increasing, we output their standard variation.
import sys
import numpy as np

def main(args):
	try:
		int_args = [float(x) for x in args]
		#if int_args[1] < int_args[0] or int_args[2] < int_args[1]:
			#print("0.000")
			#return
		#else:
		print(np.std(int_args))
	except:
		raise ValueError("cannot turn all element to int")

if __name__ == "__main__":
	args = sys.argv[1:]
	if len(args) != 3:
		raise ValueError("the length of arguments must be 3")
	main(args)