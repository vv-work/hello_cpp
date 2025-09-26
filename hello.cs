using System.Collections.Generic;

public class Hello
{
    public static void Main()
    {
        List<string> list = new List<string> { "Hello", "World" };
        foreach (var item in list)
        {
            System.Console.WriteLine(item);
        }
    }
}
