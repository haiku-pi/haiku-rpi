// dotnet-hello.cs — a .NET check for Wine Mono on the Pi: compile it there with Mono's compiler and run it:
//   wine "C:\\windows\\mono\\mono-2.0\\lib\\mono\\4.5\\mcs.exe" "-r:C:\\windows\\mono\\mono-2.0\\lib\\mono\\4.5-api\\System.dll" dotnet-hello.cs
//   wine dotnet-hello.exe
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

class Hello {
	static void Main() {
		Console.WriteLine("hello from .NET: runtime " + Environment.Version
			+ ", process " + RuntimeInformation.ProcessArchitecture
			+ ", OS " + RuntimeInformation.OSDescription);
		var sw = Stopwatch.StartNew();
		long sum = 0;
		for (int i = 0; i < 200000000; i++)
			sum += i % 7;
		Console.WriteLine("loop: sum " + sum + " in " + sw.ElapsedMilliseconds + " ms");
	}
}
