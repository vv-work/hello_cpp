class HelloPython:
    def __init__(self, name: str = "World"):
        self.name = name

    def greet(self) -> str:
        return f"Hello, {self.name}!"

if __name__ == "__main__":
    hello = HelloPython()
    print(hello.greet())

