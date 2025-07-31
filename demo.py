# Write a fibonacci function
def fibonacci(n):
    """Returns the nth Fibonacci number."""
    if n <= 0:
        return 0
    elif n == 1:
        return 1
    else:
        return fibonacci(n - 1) + fibonacci(n - 2)
# Example usage
if __name__ == "__main__": 
    n = 10  # Change this value to compute a different Fibonacci number
    print(f"The {n}th Fibonacci number is: {fibonacci(n)}")